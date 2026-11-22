"""Still's Gemma adapter immediately before the text-model extraction."""
from gemma_protocol import GemmaDecoder
from generation import reusable_prefix, stream_text


class GemmaEngine:
    title = 'Gemma 4 12B'
    prompt_limit = 6144
    context_limit = 8192
    decoder = GemmaDecoder

    def __init__(self, path):
        from mlx_vlm import load
        self.model, self.processor = load(path)
        self.cache = None
        self.cache_tokens = []

    def prepare(self, messages):
        from mlx_vlm.prompt_utils import apply_chat_template
        # Follow the official template: completed earlier thinking is omitted.
        prompt = apply_chat_template(self.processor, self.model.config, messages, enable_thinking=True)
        tokenizer = self.processor.tokenizer if hasattr(self.processor, 'tokenizer') else self.processor
        return prompt, tokenizer.encode(prompt, add_special_tokens=False)

    def generate(self, prompt, tokens, limit):
        from mlx_vlm.models.cache import make_prompt_cache
        from mlx_vlm.sample_utils import make_sampler
        from mlx_vlm.tokenizer_utils import make_streaming_detokenizer
        tokenizer = self.processor.tokenizer if hasattr(self.processor, 'tokenizer') else self.processor
        prefix = reusable_prefix(self.cache_tokens, tokens, self.cache)
        cache = self.cache if prefix else make_prompt_cache(self.model.language_model)
        cache_key = tokens[:]
        complete = False
        try:
            def forward(ids):
                # The text model performs its own embedding and scaling. No
                # vision preprocessing or upstream generation dispatch is needed.
                return self.model.language_model(ids, cache=cache, logits_to_keep=1).logits

            for result in stream_text(forward, tokens[prefix:], cache,
                    make_sampler(temp=1.0, top_p=0.95, top_k=64),
                    make_streaming_detokenizer(self.processor), tokenizer.stopping_criteria,
                    limit, cache_eval_interval=50, cached_tokens=prefix):
                if result.token is not None:
                    cache_key.append(result.token)
                yield result
            self.cache, self.cache_tokens = cache, cache_key
            complete = True
        finally:
            if not complete:
                self.cache, self.cache_tokens = None, []

