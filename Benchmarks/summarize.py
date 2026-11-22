"""Validate recorded comparisons and write the human-readable result table."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
reports = [(name, json.loads((ROOT / 'Benchmarks' / file).read_text())) for name, file in [
    ('Inkling 2 Mini', 'inkling-results.json'), ('Gemma 4 12B', 'gemma-results.json')]]
changed_sources = set()
lines = [
    '# Generation-loop results', '',
    'Measured on this Apple M2 Max Mac with 32 GB unified memory, on battery power. '
    'The previous installed adapter is the reference. Both implementations use the '
    'same loaded weights, tokenizers, model classes and sampling settings.', '',
    'The recorded Still adapter passes exact reference parity and the 2% median '
    'performance-regression gate for every measured workload. This is a bounded '
    'local comparison, not proof of identical speed on every prompt or machine.', '',
    '## Performance', '',
    'Five alternating pairs per workload and model, 128 generated-token budget: '
    '80 timed generations in total, plus unmeasured warm-ups and cache preparation. '
    'Each cell shows **previous → Still** medians.', '',
    '| Model | Workload | Decode tokens/s | Total seconds | First token seconds | Peak MLX GB |',
    '| --- | --- | ---: | ---: | ---: | ---: |',
]
labels = {'short': 'Short prompt', 'long': 'Long prompt',
          'warm-followup': 'Long follow-up', 'cached-followup': 'Cached follow-up'}
for name, report in reports:
    assert all(report['performance_gate'].values()), report['performance_gate']
    for path, digest in report['files'].items():
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest:
            changed_sources.add(path)
    for check in report['correctness']:
        if 'checks' in check:
            for field, value in check['checks'].items():
                assert value < .001 if field == 'first_logprobs_max_abs_error' else value
        if 'answer_equal' in check:
            assert check['answer_equal']
    assert len(report['measurements']) == 40
    for case, values in report['summary'].items():
        for iteration in range(5):
            pair = [r for r in report['measurements'] if r['case'] == case and r['iteration'] == iteration]
            assert len(pair) == 2
            assert pair[0]['tokens'] == pair[1]['tokens']
            assert pair[0]['text'] == pair[1]['text']
        a, b = values['previous'], values['still']
        metrics = [f"{a[key]:.{digits}f} → {b[key]:.{digits}f}" for key, digits in [
            ('decode_tps', 2), ('seconds', 3), ('first_token_seconds', 3), ('peak_gb', 3)]]
        lines.append('| ' + ' | '.join([name, labels[case], *metrics]) + ' |')
lines += [
    '', 'Time to first token includes reasoning tokens, not just visible answer text. '
    'Model loading and tokenization are excluded. Total time includes final GPU '
    'synchronization. Peak memory measures MLX active memory, not total system RAM.', '',
    'The long follow-up reuses Inkling’s cache. Gemma’s 1,024-token sliding window '
    'has evicted part of the needed history in that case, so both implementations '
    'safely recompute it. The shorter cached-follow-up case exercises reuse in both.', '',
    '## Correctness and cleanup', '',
    '- Exact old/new token IDs, decoded text, reasoning/answer fields, completion '
    'counts and finish reasons in seeded, greedy, Unicode, EOS and multi-turn cases.',
    '- Matching first-token log-probability vectors for short, long and cached '
    'prompts. Recorded maximum absolute differences are zero.',
    '- Both math turns produce correct answers; interrupted generation discards '
    'partial cache state and retries correctly.',
    '- Fresh server processes for both models pass two-turn streaming/nonstreaming '
    'HTTP checks, separate reasoning fields and context-budget rejection.',
    '- 23 Python tests pass in both pinned environments, including one-token limits, '
    'immediate EOS, cache alignment, unsafe cache rewinds, GPU stream scope, '
    'cancellation, error cleanup, HTTP framing and channel parsing. Nine Swift tests pass.',
    '', 'Inkling’s warm and cold paths can differ in reasoning wording because '
    'prefill/decode batch shapes change quantized numerical results. This also occurs '
    'in the unchanged reference. Comparing identical cache conditions produces exact '
    'parity. Rebuilding the prefix with the same batch shapes reproduces the warm '
    'scores exactly; see `check_cache_numerics.py`.', '',
    '## Investigation notes and limits', '',
    'An early version showed a small decode slowdown. The final loop keeps token '
    'reshaping and the entire decode lifecycle in the generation stream, avoiding '
    'unintended default-stream dependencies. A regression test checks stream scope '
    'and restores the caller’s stream on completion.', '',
    'One exploratory Gemma process reported a Metal GPU recovery error. It did not '
    'recur in the accepted final runs. The earlier failed run was retained locally '
    'in `diagnostics/gemma-metal-recovery.log`; its root cause was not established.', '',
    'Absolute throughput varied during battery-powered testing. The 2% tolerance '
    'applies to median total duration and decode throughput; the table separately '
    'reports first-token latency and peak memory. The raw files preserve every '
    'accepted-run trial, including slow samples. No speedup outside these workloads '
    'is claimed.', '',
    '## Reproduce', '',
    'See [methodology and commands](README.md). Raw accepted runs: '
    '[Inkling](inkling-results.json), [Gemma](gemma-results.json). The JSON files '
    'include pinned package versions, model-config hashes, production-source hashes '
    'and benchmark-source hashes.', '',
]
(ROOT / 'Benchmarks/RESULTS.md').write_text('\n'.join(lines))
print('Validated the recorded comparisons and wrote Benchmarks/RESULTS.md')
if changed_sources:
    print('Sources changed since those runs:', ', '.join(sorted(changed_sources)))
