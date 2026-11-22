"""Explain Inkling's warm/cold rounding difference with a controlled replay.

Run with Still's Inkling Python environment. The production loop is unchanged.
"""
import json
from pathlib import Path

from compare_generation import greedy_sampling, model_engines, previous_engines, reset, run, mx
from mlx_lm.models.cache import make_prompt_cache


def main():
    path = Path.home() / '.lmstudio/models/mlx-community/Inkling-2-Mini-4bit'
    current = model_engines.InklingEngine(str(path))
    reference = previous_engines.InklingEngine.__new__(previous_engines.InklingEngine)
    reference.model, reference.tokenizer = current.model, current.tokenizer
    question = [{'role': 'user', 'content': 'A notebook and a pen cost $11 together. The notebook costs $10 more than the pen. What does the pen cost? Think briefly and answer in one sentence.'}]
    results = []
    for engine, previous in [(reference, True), (current, False)]:
        reset(engine, 'inklingMini', previous)
        with greedy_sampling('inklingMini'):
            first = run(engine, question, 512)
            followup = question + [dict(role='assistant', content=first['answer'], reasoning_content=first['reasoning']),
                                   dict(role='user', content='Change the total to $13. Now what does the pen cost? Answer briefly.')]
            _, tokens = engine.prepare(followup)
            _, rest = engine.cache.fetch_nearest_cache('inkling', tokens)
            prefix = len(tokens) - len(rest)
            assert prefix > 0
            warm = run(engine, followup, 96, probe=True)
            reset(engine, 'inklingMini', previous)
            cold = run(engine, followup, 96, probe=True)
        results.append((warm, cold))

    # Same model, same prefix IDs, same batch shapes, but no sampling/generation
    # of the first answer. This separates cache-state correctness from the
    # different arithmetic used for a full prefill versus one-token decoding.
    reset(current, 'inklingMini')
    cache = make_prompt_cache(current.model)
    _, initial = current.prepare(question)
    cut = len(initial) - 1
    current.model(mx.array([tokens[:cut]]), cache=cache)
    mx.eval([c.state for c in cache])
    for token in tokens[cut:prefix]:
        current.model(mx.array([[token]]), cache=cache)
        mx.eval([c.state for c in cache])
    current.cache.insert_cache('inkling', tokens[:prefix], cache)
    with greedy_sampling('inklingMini'):
        staged = run(current, followup, 96, probe=True)

    for mode in [0, 1]:
        assert results[0][mode]['tokens'] == results[1][mode]['tokens']
        assert results[0][mode]['scores'] == results[1][mode]['scores']
    assert staged['tokens'] == results[1][0]['tokens']
    assert staged['scores'] == results[1][0]['scores']
    assert results[0][0]['answer'] == results[0][1]['answer'] == 'The pen costs $1.50.'
    print(json.dumps(dict(reference_parity=True, staged_prefix_parity=True,
                          cached_tokens=prefix, answer=staged['answer'],
                          warm_cold_tokens_equal=results[0][0]['tokens'] == results[0][1]['tokens'])))


if __name__ == '__main__':
    main()
