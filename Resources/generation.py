"""Still's single-sequence, text-only MLX generation loop.

This module owns prefill, GPU scheduling, decode, stopping and stream finalization.
"""
from contextlib import contextmanager
from dataclasses import dataclass

import mlx.core as mx


_stream = mx.new_thread_local_stream(mx.default_device())


@dataclass
class GenerationResult:
    text: str
    token: int | None
    generation_tokens: int
    finish_reason: str | None = None
    logprobs: object = None
    cached_tokens: int = 0


@contextmanager
def generation_memory():
    """Keep the same Metal working-set allowance as the upstream loops."""
    previous = None
    if mx.metal.is_available():
        previous = mx.set_wired_limit(mx.device_info()['max_recommended_working_set_size'])
    try:
        yield
    finally:
        # The next token can still be executing when a consumer closes the stream.
        mx.synchronize(_stream)
        if previous is not None:
            mx.set_wired_limit(previous)


def stream_text(forward, tokens, cache, sampler, detokenizer, is_stop, limit,
                *, prefill_size=512, cache_eval_interval=0, cached_tokens=0):
    """Yield each sampled token once; the final flush has no duplicate token.

``forward`` takes a [1, sequence] array and mutates ``cache``. One decode step
is scheduled ahead, so after successful completion the cache includes every
sampled token, including EOS. Interrupted calls must discard their cache.
    """
    if not tokens or limit < 1 or prefill_size < 1:
        raise ValueError('Generation needs a nonempty prompt and positive limits.')
    detokenizer.reset()

    def step(ids):
        with mx.stream(_stream):
            # Even a reshape belongs on the generation stream: creating it on
            # the default stream adds a cross-stream dependency every token.
            logits = forward(ids.reshape(1, -1))[:, -1, :]
            logprobs = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
            return sampler(logprobs), logprobs.squeeze(0)

    # Keep scheduling, scalar reads and detokenization callbacks on the same
    # stream too, not just the model calls. MLX's default stream is contextual.
    with generation_memory(), mx.stream(_stream):
        with mx.stream(_stream):
            remaining = mx.array(tokens)[None]
            while remaining.shape[1] > 1:
                count = min(prefill_size, remaining.shape[1] - 1)
                forward(remaining[:, :count])
                mx.eval([entry.state for entry in cache])
                remaining = remaining[:, count:]
                mx.clear_cache()
            current, logprobs = step(remaining)
            mx.async_eval(current, logprobs)

        finish = 'length'
        stop_token = None
        for index in range(limit):
            # Pipeline GPU decoding with the CPU's detokenization and HTTP work.
            following, next_logprobs = step(current)
            mx.async_eval(following, next_logprobs)
            if index == 0:
                mx.eval(current)
            token = current.item()
            if cache_eval_interval and (index + 1) % cache_eval_interval == 0:
                mx.eval([entry.state for entry in cache])
            if is_stop(token):
                finish, stop_token = 'stop', token
                break
            detokenizer.add_token(token)
            yield GenerationResult(detokenizer.last_segment, token, index + 1,
                                   logprobs=logprobs, cached_tokens=cached_tokens)
            if index % 256 == 0:
                mx.clear_cache()
            current, logprobs = following, next_logprobs

        detokenizer.finalize()
        yield GenerationResult(detokenizer.last_segment, stop_token, index + 1,
                               finish, logprobs, cached_tokens)


def reusable_prefix(saved_tokens, tokens, cache):
    """Trim only reversible cache state; otherwise request a fresh prefill.

The final prompt token is always evaluated to obtain next-token scores. A
sliding window which has evicted history cannot be rewound to an older prefix.
    """
    if not cache or not saved_tokens:
        return 0
    prefix = 0
    for old, new in zip(saved_tokens, tokens[:-1]):
        if old != new:
            break
        prefix += 1
    if not prefix:
        return 0
    offsets = [int(entry.offset) for entry in cache]
    if len(set(offsets)) != 1 or offsets[0] < prefix:
        return 0
    drop = offsets[0] - prefix
    if drop:
        for entry in cache:
            if not entry.is_trimmable():
                return 0
            capacity = getattr(entry, 'max_size', None)
            if capacity is not None and entry.offset > capacity:
                return 0
        for entry in cache:
            if entry.trim(drop) != drop:
                # Caller discards all entries if any trim could not be applied.
                return 0
    return prefix
