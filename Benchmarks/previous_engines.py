"""Model computations behind Still's server; no upstream server is imported."""
from inkling_protocol import InklingDecoder
from gemma_protocol import GemmaDecoder


class InklingEngine:
    title = 'Inkling 2 Mini'
    prompt_limit = 3072
    context_limit = 4096
    decoder = InklingDecoder

    def __init__(self, path):
        from mlx_lm import load
        from mlx_lm.models.cache import LRUPromptCache
        self.model, self.tokenizer = load(path)
        self.cache = LRUPromptCache(max_size=1, max_bytes=512 * 1024 * 1024)

    def prepare(self, messages):
        tokens = self.tokenizer.apply_chat_template(messages, tokenize=True, add_generation_prompt=True, reasoning_effort='low')
        return None, tokens

    def generate(self, prompt, tokens, limit):
        from mlx_lm import stream_generate
        from mlx_lm.models.cache import LRUPromptCache, make_prompt_cache
        from mlx_lm.sample_utils import make_sampler
        cache, rest = self.cache.fetch_nearest_cache('inkling', tokens)
        if cache is None:
            cache = make_prompt_cache(self.model)
        cache_key = tokens[:]
        complete = False
        try:
            for result in stream_generate(self.model, self.tokenizer, rest, max_tokens=limit,
                    sampler=make_sampler(temp=0.7, top_p=0.95), prompt_cache=cache, prefill_step_size=512):
                cache_key.append(result.token)
                yield result
            self.cache.insert_cache('inkling', cache_key, cache)
            complete = True
        finally:
            if not complete:
                self.cache = LRUPromptCache(max_size=1, max_bytes=512 * 1024 * 1024)


class GemmaEngine:
    title = 'Gemma 4 12B'
    prompt_limit = 6144
    context_limit = 8192
    decoder = GemmaDecoder

    def __init__(self, path):
        from mlx_vlm import load
        from mlx_vlm.generate.common import PromptCacheState
        self.model, self.processor = load(path)
        self.cache = PromptCacheState()

    def prepare(self, messages):
        from mlx_vlm.prompt_utils import apply_chat_template
        # Follow the official template: completed earlier thinking is omitted.
        prompt = apply_chat_template(self.processor, self.model.config, messages, enable_thinking=True)
        tokenizer = self.processor.tokenizer if hasattr(self.processor, 'tokenizer') else self.processor
        return prompt, tokenizer.encode(prompt, add_special_tokens=False)

    def generate(self, prompt, tokens, limit):
        import mlx.core as mx
        from mlx_vlm import stream_generate
        from mlx_vlm.generate.common import PromptCacheState
        complete = False
        try:
            yield from stream_generate(self.model, self.processor, prompt, input_ids=mx.array([tokens]),
                max_tokens=limit, temperature=1.0, top_p=0.95, top_k=64,
                prefill_step_size=512, skip_special_tokens=False, prompt_cache_state=self.cache)
            complete = True
        finally:
            if not complete:
                self.cache = PromptCacheState()


ENGINES = {'inklingMini': InklingEngine, 'gemma12B': GemmaEngine}
