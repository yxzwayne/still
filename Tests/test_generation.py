import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Resources'))
HAS_MLX = importlib.util.find_spec('mlx') is not None
if HAS_MLX:
    import mlx.core as mx
    from generation import _stream, reusable_prefix, stream_text


class Cache:
    def __init__(self, offset=0, capacity=None, trimmable=True):
        self.offset = offset
        self.max_size = capacity
        self.trimmable = trimmable
        self.seen = []

    @property
    def state(self):
        return mx.array([self.offset])

    def is_trimmable(self):
        return self.trimmable

    def trim(self, count):
        self.offset -= count
        return count


class Detokenizer:
    def reset(self):
        self.last_segment = ''

    def add_token(self, token):
        self.last_segment = str(token)

    def finalize(self):
        self.last_segment = '!'


@unittest.skipUnless(HAS_MLX, 'Run with a pinned Still Python environment for MLX tests')
class GenerationTests(unittest.TestCase):
    def make_generation(self, prompt, limit, stop=7, prefill=2):
        cache = Cache()
        def forward(ids):
            values = ids.flatten().tolist()
            cache.seen.extend(values)
            cache.offset += len(values)
            next_token = (values[-1] + 1) % 8
            return mx.where(mx.arange(8) == next_token, 10., -10.).reshape(1, 1, 8)
        gen = stream_text(forward, prompt, [cache], lambda x: mx.argmax(x, axis=-1),
                          Detokenizer(), lambda token: token == stop, limit,
                          prefill_size=prefill)
        return gen, cache

    def test_eos_flush_and_cache_alignment(self):
        gen, cache = self.make_generation([1, 2, 3], 10)
        events = list(gen)
        self.assertEqual(''.join(e.text for e in events), '456!')
        self.assertEqual([e.token for e in events], [4, 5, 6, 7])
        self.assertEqual(events[-1].finish_reason, 'stop')
        self.assertEqual(events[-1].generation_tokens, 4)
        self.assertEqual(cache.seen, [1, 2, 3, 4, 5, 6, 7])

    def test_limit_one_and_no_duplicate_final_token(self):
        gen, cache = self.make_generation([1], 1)
        events = list(gen)
        self.assertEqual([e.token for e in events], [2, None])
        self.assertEqual(''.join(e.text for e in events), '2!')
        self.assertEqual(events[-1].finish_reason, 'length')
        self.assertEqual(cache.seen, [1, 2])

    def test_immediate_eos(self):
        gen, cache = self.make_generation([6], 8)
        events = list(gen)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].token, 7)
        self.assertEqual(events[0].text, '!')
        self.assertEqual(cache.seen, [6, 7])

    def test_chunk_sizes_preserve_tokens(self):
        for chunk in [1, 2, 512]:
            gen, cache = self.make_generation([0, 1, 2, 3], 2, prefill=chunk)
            self.assertEqual([e.token for e in gen], [4, 5, None])
            self.assertEqual(cache.seen, [0, 1, 2, 3, 4, 5])

    def test_close_restores_memory_limit(self):
        with patch('generation.mx.set_wired_limit', wraps=mx.set_wired_limit) as limit:
            gen, _ = self.make_generation([1], 8)
            next(gen)
            gen.close()
            if mx.metal.is_available():
                self.assertEqual(limit.call_count, 2)

    def test_stream_scope_covers_token_callbacks_and_restores_caller(self):
        caller_stream = mx.default_stream(mx.default_device())
        with mx.stream(_stream):
            expected = mx.default_stream(mx.default_device())
        observed = []
        class StreamAwareDetokenizer(Detokenizer):
            def add_token(self, token):
                observed.append(mx.default_stream(mx.default_device()))
                super().add_token(token)
        cache = Cache()
        def forward(ids):
            return mx.array([[[0., 10., -10.]]])
        gen = stream_text(forward, [0], [cache], lambda x: mx.argmax(x, axis=-1),
                          StreamAwareDetokenizer(), lambda _: False, 2)
        list(gen)
        self.assertEqual(observed, [expected, expected])
        self.assertEqual(mx.default_stream(mx.default_device()), caller_stream)

    def test_invalid_inputs(self):
        for prompt, limit in [([], 1), ([1], 0)]:
            gen, _ = self.make_generation(prompt, limit)
            with self.assertRaises(ValueError):
                next(gen)

    def test_model_error_restores_memory_limit(self):
        def fail(_):
            raise RuntimeError('fixture model failed')
        with patch('generation.mx.set_wired_limit', wraps=mx.set_wired_limit) as limit:
            gen = stream_text(fail, [1], [Cache()], None, Detokenizer(), lambda _: False, 2)
            with self.assertRaisesRegex(RuntimeError, 'fixture model failed'):
                next(gen)
            if mx.metal.is_available():
                self.assertEqual(limit.call_count, 2)

    def test_safe_prefix_trim_and_exact_retry(self):
        cache = [Cache(4), Cache(4, 8)]
        self.assertEqual(reusable_prefix([1, 2, 3, 4], [1, 2, 3, 9], cache), 3)
        self.assertEqual([c.offset for c in cache], [3, 3])
        self.assertEqual(reusable_prefix([1, 2, 3], [1, 2, 3], cache), 2)

    def test_evicted_hybrid_or_misaligned_state_cannot_rewind(self):
        for cache in [[Cache(9, 4)], [Cache(4, trimmable=False)], [Cache(4), Cache(3)]]:
            before = [c.offset for c in cache]
            self.assertEqual(reusable_prefix([1, 2, 3, 4], [1, 2, 9], cache), 0)
            self.assertEqual([c.offset for c in cache], before)


if __name__ == '__main__':
    unittest.main()
