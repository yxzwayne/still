"""Gemma 4 Unified text forward pass adapted from MLX-VLM 0.8.0. See LICENSE."""

from dataclasses import dataclass
from functools import partial
import json
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn

from .cache import KVCache, RotatingKVCache


@dataclass(frozen=True)
class TextConfig:
    hidden_size: int
    intermediate_size: int
    vocab_size: int
    num_attention_heads: int
    num_key_value_heads: int
    num_global_key_value_heads: int
    head_dim: int
    global_head_dim: int
    layer_types: list[str]
    sliding_window: int
    rope_parameters: dict
    rms_norm_eps: float
    final_logit_softcapping: float

    @classmethod
    def from_checkpoint(cls, config):
        text = config['text_config']
        supported = (
            config['model_type'] == 'gemma4_unified'
            and text['model_type'] == 'gemma4_unified_text'
            and text['attention_k_eq_v']
            and text['tie_word_embeddings']
            and text['hidden_activation'] == 'gelu_pytorch_tanh'
            and not text['attention_bias']
            and not text.get('per_layer_config')
            and not text.get('rope_traditional')
            and not text['enable_moe_block']
            and not text['num_kv_shared_layers']
            and not text['hidden_size_per_layer_input']
            and not text['use_double_wide_mlp']
            and len(text['layer_types']) == text['num_hidden_layers']
            and set(text['layer_types']) <= {'full_attention', 'sliding_attention'}
            and text['rope_parameters']['full_attention']['rope_type'] == 'proportional'
            and text['rope_parameters']['sliding_attention']['rope_type'] == 'default'
        )
        if not supported:
            raise ValueError('Unsupported Gemma text checkpoint configuration.')
        return cls(**{name: text[name] for name in cls.__dataclass_fields__})


class ProportionalRoPE(nn.Module):
    def __init__(self, dims, parameters):
        super().__init__()
        self.dims = dims
        rotated_dims = 2 * int(parameters['partial_rotary_factor'] * dims // 2)
        exponents = mx.arange(0, rotated_dims, 2, dtype=mx.float32) / dims
        freqs = parameters.get('factor', 1.0) * mx.power(parameters['rope_theta'], exponents)
        unrotated = (dims - rotated_dims) // 2
        # Infinite frequencies give the unrotated channels zero phase.
        self._freqs = mx.concatenate([freqs, mx.full((unrotated,), mx.inf, dtype=mx.float32)])
        mx.eval(self._freqs)

    def __call__(self, x, offset):
        return mx.fast.rope(x, self.dims, traditional=False, base=None,
                            scale=1.0, offset=offset, freqs=self._freqs)


@partial(mx.compile, shapeless=True)
def geglu(gate, x):
    return nn.gelu_approx(gate) * x


@partial(mx.compile, shapeless=True)
def logit_softcap(softcap, x):
    return mx.tanh(x / softcap) * softcap


class MLP(nn.Module):
    def __init__(self, config):
        super().__init__()
        self.gate_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=False)
        self.down_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=False)
        self.up_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=False)

    def __call__(self, x):
        return self.down_proj(geglu(self.gate_proj(x), self.up_proj(x)))


class Attention(nn.Module):
    def __init__(self, config, layer_type):
        super().__init__()
        self.is_full = layer_type == 'full_attention'
        self.head_dim = config.global_head_dim if self.is_full else config.head_dim
        self.n_heads = config.num_attention_heads
        self.n_kv_heads = (config.num_global_key_value_heads if self.is_full
                           else config.num_key_value_heads)
        dim = config.hidden_size
        kv_dim = self.n_kv_heads * self.head_dim
        self.q_proj = nn.Linear(dim, self.n_heads * self.head_dim, bias=False)
        self.k_proj = nn.Linear(dim, kv_dim, bias=False)
        if not self.is_full:
            self.v_proj = nn.Linear(dim, kv_dim, bias=False)
        self.o_proj = nn.Linear(self.n_heads * self.head_dim, dim, bias=False)
        self.q_norm = nn.RMSNorm(self.head_dim, eps=config.rms_norm_eps)
        self.k_norm = nn.RMSNorm(self.head_dim, eps=config.rms_norm_eps)
        self.eps = config.rms_norm_eps
        rope = config.rope_parameters[layer_type]
        self.rope = (ProportionalRoPE(self.head_dim, rope) if self.is_full
                     else nn.RoPE(self.head_dim, traditional=False, base=rope['rope_theta']))

    def __call__(self, x, mask, cache):
        batch, length, _ = x.shape
        queries = self.q_proj(x).reshape(batch, length, self.n_heads, self.head_dim)
        queries = self.q_norm(queries)
        keys = self.k_proj(x).reshape(batch, length, self.n_kv_heads, self.head_dim)
        # Full attention's values come from the raw key projection.
        values = keys if self.is_full else self.v_proj(x).reshape(keys.shape)
        offset = mx.array(cache.offset)
        keys = self.rope(self.k_norm(keys).transpose(0, 2, 1, 3), offset=offset)
        values = mx.fast.rms_norm(values, None, self.eps).transpose(0, 2, 1, 3)
        keys, values = cache.update_and_fetch(keys, values)
        queries = self.rope(queries.transpose(0, 2, 1, 3), offset=offset)
        output = mx.fast.scaled_dot_product_attention(
            queries, keys, values, scale=1.0, mask=mask, sinks=None
        )
        return self.o_proj(output.transpose(0, 2, 1, 3).reshape(batch, length, -1))


class DecoderLayer(nn.Module):
    def __init__(self, config, layer_type):
        super().__init__()
        self.layer_type = layer_type
        self.self_attn = Attention(config, layer_type)
        self.mlp = MLP(config)
        self.input_layernorm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.pre_feedforward_layernorm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_feedforward_layernorm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.layer_scalar = mx.ones((1,))

    def __call__(self, x, mask, cache):
        h = self.self_attn(self.input_layernorm(x), mask, cache)
        h = x + self.post_attention_layernorm(h)
        residual = h
        h = self.mlp(self.pre_feedforward_layernorm(h))
        h = residual + self.post_feedforward_layernorm(h)
        return h * self.layer_scalar


class TextModel(nn.Module):
    def __init__(self, config):
        super().__init__()
        self.config = config
        self.embed_tokens = nn.Embedding(config.vocab_size, config.hidden_size)
        self.embed_scale = config.hidden_size**0.5
        self.layers = [DecoderLayer(config, layer_type) for layer_type in config.layer_types]
        self.norm = nn.RMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def make_cache(self):
        return [KVCache() if layer.layer_type == 'full_attention'
                else RotatingKVCache(self.config.sliding_window) for layer in self.layers]

    def __call__(self, ids, cache):
        h = self.embed_tokens(ids) * self.embed_scale
        masks = {}
        for layer, entry in zip(self.layers, cache, strict=True):
            if layer.layer_type not in masks:
                masks[layer.layer_type] = entry.make_mask(ids.shape[1])
        for layer, entry in zip(self.layers, cache):
            h = layer(h, masks[layer.layer_type], entry)
        h = self.norm(h)
        logits = self.embed_tokens.as_linear(h[:, -1:, :])
        return logit_softcap(self.config.final_logit_softcapping, logits)


def load(path, config):
    model = TextModel(TextConfig.from_checkpoint(config))
    quantization = config['quantization']
    if quantization != {'group_size': 64, 'bits': 4, 'mode': 'affine'}:
        raise ValueError('Unsupported Gemma text checkpoint quantization.')

    directory = Path(path)
    index = json.loads((directory / 'model.safetensors.index.json').read_text())
    prefix = 'language_model.model.'
    shards = {}
    for name, shard in index['weight_map'].items():
        if name.startswith(prefix):
            shards.setdefault(shard, []).append(name)
    if not shards:
        raise ValueError('No language model weights found in the Gemma checkpoint.')
    weights = {}
    for shard, names in sorted(shards.items()):
        if Path(shard).name != shard or not shard.endswith('.safetensors'):
            raise ValueError(f'Invalid Gemma weight shard {shard!r}.')
        contents = mx.load(str(directory / shard))
        weights.update((name.removeprefix(prefix), contents[name]) for name in names)
    del contents

    def quantize_module(name, module):
        return hasattr(module, 'to_quantized') and f'{name}.scales' in weights

    nn.quantize(model, **quantization, class_predicate=quantize_module)
    model.load_weights(list(weights.items()), strict=True)
    model.eval()
    mx.eval(model.parameters())
    return model
