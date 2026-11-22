# Still inference verification

## Gemma text extraction

On an Apple Silicon Mac with the pinned checkpoint and the original
`GemmaRuntime` installed, build Still, quit any running inference process, and run
this from the project directory:

```sh
Scripts/build.sh
Benchmarks/verify_gemma_text.sh
```

The script installs the standalone lock into a temporary interpreter, confirms
neither upstream model package is installed, and sends a two-turn request
through the bundled server. It then uses the original environment to compare
the extracted model with [the previous Still adapter](gemma_reference.py).
Recreate the old interpreter with `GemmaReference.requirements.txt` if needed.

The comparison checks prompt token IDs, generated tokens, streamed text,
reasoning and answers, first-token log probabilities, EOS, and retry after
cancellation. The two follow-up workloads verify prefix reuse and safe fallback
after sliding-window eviction. The harness loads both models independently from
the same checkpoint and runs five alternating pairs per workload. It records
first-token time, decode rate, total time and MLX memory. Since both sets of
weights are resident, `peak_extra_gb` reports the increase in active MLX memory
over the start of a request. The result is written to `gemma-text-results.json`,
with a 2% gate on median total time and decode rate.

The clean interpreter and tokenizer checks ran in the development session.
The session lacked Metal and loopback access, so the real-model smoke and
comparison still require the Mac Terminal run above.

## Generation-loop comparison

`previous_engines.py` is the Still adapter before the generation-loop rewrite.
It delegates generation to the pinned upstream libraries and is retained only
as the benchmark reference. It is not copied into the app bundle.

`compare_generation.py` loads one model and gives each implementation its own
mutable cache. It compares seeded and greedy token IDs, complete decoded text,
separate reasoning/answer text, completion counts and finish reasons. The first
next-token log-probability vector is also compared for a short and long prompt.
Real-model checks cover Unicode, EOS, multiple turns, warm versus cold caches,
and an interrupted generator followed by retry.

Inkling's cached and cold computations produce slightly different numerical
scores because their prefill/decode batch shapes differ. The observed example
adds a sentence to the reasoning but retains the correct final answer. This
also happens in the unchanged reference. The required parity is current versus
reference with the same cache state, including exact token/text equality and
matching first-token scores. Both warm and cold math answers are checked.
`check_cache_numerics.py` independently rebuilds the prefix with matching batch
shapes; it reproduces the cached scores and tokens exactly without generating
the first answer. Gemma's warm/cold token sequences also match in this fixture.

Performance measurements use the same weights, prompt IDs, sampling settings,
seed and 128-token output budget. Both paths warm up before timing. Run order
alternates each pair. The current harness releases both adapters' old caches
before every trial, then prepares only the measured implementation's cache.
The models must run sequentially, with no other inference process active.

- `short`: fresh cache, short question.
- `long`: fresh cache, a prompt crossing multiple 512-token prefill chunks.
- `warm-followup`: follow-up to the long prompt. For Gemma this exceeds its
  1,024-token attention window, exercising safe fallback to a fresh prefill.
- `cached-followup`: follow-up to a shorter repeated passage, allowing Gemma
  to reuse a substantial prefix without rewinding an evicted window.

Measurements are taken around the adapter, including cache lookup and stream
finalization, but excluding model loading and chat-template/tokenizer work.
`first_token_seconds` measures the first sampled token, including reasoning;
it is not time to the first visible answer character. `decode_tps` excludes
prefill and uses observed distinct token arrivals. `seconds` includes final GPU
synchronization. `peak_gb` is MLX peak active memory, not whole-system RAM.

Run from the Still source directory:

```sh
"$HOME/Library/Application Support/Still/Runtime/bin/python" \
  Benchmarks/compare_generation.py --profile inklingMini \
  --output /tmp/still-inkling-generation-results.json

"$HOME/Library/Application Support/Still/GemmaRuntime/bin/python" \
  Benchmarks/compare_generation.py --profile gemma12B \
  --output /tmp/still-gemma-generation-results.json
```

Use `--mode correctness` or `--mode performance` to isolate a phase;
`--pairs 5` increases repetitions and `--cases cached-followup` selects a workload.
`--max-slowdown 1.02` fails if any workload's median total time or decode rate
regresses by more than 2%. This tolerance accommodates measurement noise; it
does not establish a universal performance guarantee. Inspect time to first
token and peak memory separately in the report.
Every report includes versions and source hashes. These are local comparative
measurements on this Mac, not guarantees for every prompt or machine.

The small-model loop tests in `Tests/test_generation.py` additionally cover
immediate EOS, an output limit of one, chunk boundaries, cancellation cleanup,
exact-prefix retries and unsafe cache rewinds. Run those tests with either pinned
Python environment; the system Python skips them when MLX is absent.
