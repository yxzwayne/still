"""Model computations behind Still's server; no upstream server is imported."""
from inkling_protocol import InklingDecoder
from gemma_protocol import GemmaDecoder
from generation import stream_text, reusable_prefix


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
        from mlx_lm.models.cache import LRUPromptCache, make_prompt_cache
        from mlx_lm.sample_utils import make_sampler
        cache, rest = self.cache.fetch_nearest_cache('inkling', tokens)
        if cache is None or not rest:
            # An exact cached prompt still needs its final logits. Hybrid state
            # cannot always be rewound, so an exact retry uses a fresh cache.
            cache = make_prompt_cache(self.model)
            rest = tokens
        cache_key = tokens[:]
        complete = False
        try:
            def forward(ids):
                return self.model(ids, cache=cache)

            for result in stream_text(forward, rest, cache,
                    make_sampler(temp=0.7, top_p=0.95), self.tokenizer.detokenizer,
                    lambda token: token in self.tokenizer.eos_token_ids, limit,
                    cached_tokens=len(tokens) - len(rest)):
                if result.token is not None:
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
        import json
        from pathlib import Path
        from still_gemma.model import load
        from still_gemma.tokenizer import ChatTokenizer

        path = Path(path)
        config = json.loads((path / 'config.json').read_text())
        self.tokenizer = ChatTokenizer(path, config)
        self.model = load(path, config)
        self.cache = None
        self.cache_tokens = []

    def prepare(self, messages):
        return self.tokenizer.prepare(messages)

    def generate(self, prompt, tokens, limit):
        from still_gemma.sampling import make_sampler

        prefix = reusable_prefix(self.cache_tokens, tokens, self.cache)
        cache = self.cache if prefix else self.model.make_cache()
        cache_key = tokens[:]
        complete = False
        try:
            def forward(ids):
                return self.model(ids, cache)

            for result in stream_text(forward, tokens[prefix:], cache,
                    make_sampler(), self.tokenizer.detokenizer(), self.tokenizer.stop_ids.__contains__,
                    limit, cache_eval_interval=50, cached_tokens=prefix):
                if result.token is not None:
                    cache_key.append(result.token)
                yield result
            self.cache, self.cache_tokens = cache, cache_key
            complete = True
        finally:
            if not complete:
                self.cache, self.cache_tokens = None, []


ENGINES = {'inklingMini': InklingEngine, 'gemma12B': GemmaEngine}
