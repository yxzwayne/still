# Generation-loop results

Measured on this Apple M2 Max Mac with 32 GB unified memory, on battery power. The previous installed adapter is the reference. Both implementations use the same loaded weights, tokenizers, model classes and sampling settings.

The recorded Still adapter passes exact reference parity and the 2% median performance-regression gate for every measured workload. This is a bounded local comparison, not proof of identical speed on every prompt or machine.

## Performance

Five alternating pairs per workload and model, 128 generated-token budget: 80 timed generations in total, plus unmeasured warm-ups and cache preparation. Each cell shows **previous → Still** medians.

| Model | Workload | Decode tokens/s | Total seconds | First token seconds | Peak MLX GB |
| --- | --- | ---: | ---: | ---: | ---: |
| Inkling 2 Mini | Short prompt | 29.20 → 30.60 | 4.675 → 4.476 | 0.324 → 0.324 | 17.456 → 17.456 |
| Inkling 2 Mini | Long prompt | 27.79 → 28.63 | 7.238 → 7.141 | 2.666 → 2.638 | 19.152 → 19.152 |
| Inkling 2 Mini | Long follow-up | 27.14 → 26.65 | 4.917 → 5.012 | 0.245 → 0.245 | 17.801 → 17.801 |
| Inkling 2 Mini | Cached follow-up | 27.11 → 26.98 | 4.905 → 4.936 | 0.218 → 0.224 | 17.603 → 17.604 |
| Gemma 4 12B | Short prompt | 30.85 → 30.74 | 4.420 → 4.443 | 0.280 → 0.289 | 6.965 → 6.965 |
| Gemma 4 12B | Long prompt | 35.95 → 36.44 | 8.550 → 8.414 | 5.008 → 4.918 | 7.729 → 7.720 |
| Gemma 4 12B | Long follow-up | 36.71 → 37.12 | 7.514 → 7.431 | 4.046 → 3.994 | 8.086 → 8.077 |
| Gemma 4 12B | Cached follow-up | 37.78 → 38.21 | 3.571 → 3.535 | 0.202 → 0.200 | 7.099 → 7.099 |

Time to first token includes reasoning tokens, not just visible answer text. Model loading and tokenization are excluded. Total time includes final GPU synchronization. Peak memory measures MLX active memory, not total system RAM.

The long follow-up reuses Inkling’s cache. Gemma’s 1,024-token sliding window has evicted part of the needed history in that case, so both implementations safely recompute it. The shorter cached-follow-up case exercises reuse in both.

## Correctness and cleanup

- Exact old/new token IDs, decoded text, reasoning/answer fields, completion counts and finish reasons in seeded, greedy, Unicode, EOS and multi-turn cases.
- Matching first-token log-probability vectors for short, long and cached prompts. Recorded maximum absolute differences are zero.
- Both math turns produce correct answers; interrupted generation discards partial cache state and retries correctly.
- Fresh server processes for both models pass two-turn streaming/nonstreaming HTTP checks, separate reasoning fields and context-budget rejection.
- 23 Python tests pass in both pinned environments, including one-token limits, immediate EOS, cache alignment, unsafe cache rewinds, GPU stream scope, cancellation, error cleanup, HTTP framing and channel parsing. Nine Swift tests pass.

Inkling’s warm and cold paths can differ in reasoning wording because prefill/decode batch shapes change quantized numerical results. This also occurs in the unchanged reference. Comparing identical cache conditions produces exact parity. Rebuilding the prefix with the same batch shapes reproduces the warm scores exactly; see `check_cache_numerics.py`.

## Investigation notes and limits

An early version showed a small decode slowdown. The final loop keeps token reshaping and the entire decode lifecycle in the generation stream, avoiding unintended default-stream dependencies. A regression test checks stream scope and restores the caller’s stream on completion.

One exploratory Gemma process reported a Metal GPU recovery error. It did not recur in the accepted final runs. The earlier failed run was retained locally in `diagnostics/gemma-metal-recovery.log`; its root cause was not established.

Absolute throughput varied during battery-powered testing. The 2% tolerance applies to median total duration and decode throughput; the table separately reports first-token latency and peak memory. The raw files preserve every accepted-run trial, including slow samples. No speedup outside these workloads is claimed.

## Reproduce

See [methodology and commands](README.md). Raw accepted runs: [Inkling](inkling-results.json), [Gemma](gemma-results.json). The JSON files include pinned package versions, model-config hashes, production-source hashes and benchmark-source hashes.
