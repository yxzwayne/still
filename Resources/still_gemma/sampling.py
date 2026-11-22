# Copyright 2023-2024 Apple Inc.
"""Gemma's nucleus, top-k and temperature sampler from MLX-VLM. See LICENSE."""

from functools import partial

import mlx.core as mx


def apply_top_p(logprobs, top_p):
    sorted_logprobs = mx.sort(logprobs, axis=-1)
    sorted_probs = mx.exp(sorted_logprobs.astype(mx.float32))
    mass_above = mx.cumsum(sorted_probs, axis=-1, reverse=True, inclusive=False)
    total_mass = mass_above[..., :1] + sorted_probs[..., :1]
    num_dropped = (mass_above >= top_p * total_mass).sum(axis=-1, keepdims=True)
    threshold = mx.take_along_axis(sorted_logprobs, num_dropped, axis=-1)
    return mx.where(logprobs < threshold, -float('inf'), logprobs)


@partial(mx.compile, inputs=mx.random.state, outputs=mx.random.state)
def apply_top_k(logprobs, top_k):
    mask_idx = mx.argpartition(-logprobs, kth=top_k - 1, axis=-1)[..., top_k:]
    return mx.put_along_axis(
        logprobs, mask_idx, mx.array(-float('inf'), logprobs.dtype), axis=-1
    )


@partial(mx.compile, inputs=mx.random.state, outputs=mx.random.state)
def categorical_sampling(logits, temp):
    return mx.random.categorical(logits * (1 / temp))


def make_sampler():
    def sample(logprobs):
        return categorical_sampling(apply_top_k(apply_top_p(logprobs, 0.95), 64), 1.0)

    return sample
