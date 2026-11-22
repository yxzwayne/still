"""Compare Still adapters with separate prompt caches and wall-clock timing."""
import argparse
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
import gc
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import statistics
import sys
import time
from unittest.mock import patch

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Resources'))
import mlx.core as mx
import model_engines
import previous_engines
from gemma_reference import GemmaEngine as GemmaReference


@contextmanager
def greedy_sampling(profile, compare):
    module = 'mlx_lm.sample_utils' if profile == 'inklingMini' else 'mlx_vlm.sample_utils'
    factory = lambda **_: lambda scores: mx.argmax(scores, axis=-1)
    with ExitStack() as stack:
        stack.enter_context(patch(module + '.make_sampler', factory))
        if profile == 'gemma12B':
            target = ('still_gemma.sampling' if compare == 'gemma-extraction'
                      else 'mlx_vlm.generate')
            stack.enter_context(patch(target + '.make_sampler', factory))
        yield


def reset(engine, profile, previous=False):
    if profile == 'inklingMini':
        from mlx_lm.models.cache import LRUPromptCache
        engine.cache = LRUPromptCache(max_size=1, max_bytes=512 * 1024 * 1024)
    elif previous:
        from mlx_vlm.generate.common import PromptCacheState
        engine.cache = PromptCacheState()
    else:
        engine.cache, engine.cache_tokens = None, []
    gc.collect()
    mx.clear_cache()


def run(engine, messages, limit, seed=123, probe=False):
    prompt, tokens = engine.prepare(messages)
    mx.synchronize()
    mx.random.seed(seed)
    active_at_start = mx.get_active_memory()
    mx.reset_peak_memory()
    decoder = engine.decoder()
    ids, answer, reasoning, text = {}, '', '', ''
    first = last = None
    scores = None
    start = time.perf_counter()
    gen = engine.generate(prompt, tokens, limit)
    try:
        for event in gen:
            now = time.perf_counter()
            if event.token is not None and event.generation_tokens not in ids:
                ids[event.generation_tokens] = event.token
                if first is None:
                    first = now
                    if probe:
                        scores = event.logprobs.astype(mx.float32).tolist()
                last = now
            a, r = decoder.feed(event.text)
            answer += a
            reasoning += r
            text += event.text
    finally:
        gen.close()
    a, r = decoder.feed('', final=True)
    answer += a
    reasoning += r
    mx.synchronize()
    elapsed = time.perf_counter() - start
    peak = mx.get_peak_memory()
    return dict(prompt_tokens=len(tokens), prompt_ids_sha256=hashlib.sha256(json.dumps(tokens).encode()).hexdigest(),
                tokens=[ids[k] for k in sorted(ids)],
                text=text, answer=answer, reasoning=reasoning, finish=event.finish_reason,
                completion_tokens=event.generation_tokens, seconds=elapsed,
                first_token_seconds=first-start, decode_tps=(len(ids)-1)/(last-first) if last>first else 0,
                peak_gb=peak/1e9, peak_extra_gb=(peak-active_at_start)/1e9,
                cached_tokens=getattr(event, 'cached_tokens', None),
                scores=scores)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=model_engines.ENGINES, required=True)
    parser.add_argument('--compare', choices=['generation-loop', 'gemma-extraction'], default='generation-loop')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['smoke', 'correctness', 'performance', 'all'], default='all')
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--tokens', type=int, default=128, help='Performance output-token budget')
    parser.add_argument('--max-slowdown', type=float, default=None,
                        help='Optional median wall-time/throughput regression gate, e.g. 1.02')
    parser.add_argument('--cases', nargs='+', choices=['short','long','warm-followup','cached-followup'],
                        default=['short','long','warm-followup','cached-followup'])
    args = parser.parse_args()
    extraction = args.compare == 'gemma-extraction'
    if extraction and args.profile != 'gemma12B':
        parser.error('--compare gemma-extraction requires --profile gemma12B')
    if args.pairs < 1 or args.tokens < 2:
        parser.error('Use at least one pair and at least two performance tokens')
    model = (Path.home()/'.lmstudio/models/mlx-community/Inkling-2-Mini-4bit' if args.profile=='inklingMini'
             else Path.home()/'Library/Application Support/Still/Models/gemma-4-12B-it-4bit')
    if extraction:
        old = GemmaReference(str(model))
        new = model_engines.GemmaEngine(str(model))
    else:
        adapter = GemmaReference if args.profile == 'gemma12B' else model_engines.InklingEngine
        new = adapter(str(model))
        reference = previous_engines.ENGINES[args.profile]
        old = reference.__new__(reference)
        old.model = new.model
        if args.profile == 'inklingMini':
            old.tokenizer = new.tokenizer
        else:
            old.processor = new.processor
    old_uses_upstream_generation = not extraction
    reset(old, args.profile, old_uses_upstream_generation)
    sources = [ROOT/'Resources/generation.py', ROOT/'Resources/model_engines.py', Path(__file__).resolve()]
    sources.append(ROOT/'Benchmarks'/('gemma_reference.py' if extraction else 'previous_engines.py'))
    if extraction:
        sources.extend(sorted((ROOT/'Resources/still_gemma').glob('*.py')))
    packages = ['mlx', 'mlx-lm' if args.profile == 'inklingMini' else 'mlx-vlm']
    if extraction:
        packages.extend(['mlx-metal', 'jinja2', 'tokenizers', 'transformers'])
    report = dict(profile=args.profile, comparison=args.compare, machine=platform.platform(), python=sys.version,
                  started_utc=datetime.now(timezone.utc).isoformat(),
                  model_config_sha256=hashlib.sha256((model/'config.json').read_bytes()).hexdigest(),
                  versions={p:importlib.metadata.version(p) for p in packages},
                  files={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                  correctness=[], measurements=[])
    parity_fields = ['prompt_ids_sha256', 'tokens', 'text', 'answer', 'reasoning', 'finish', 'completion_tokens']
    if extraction:
        parity_fields.append('cached_tokens')

    def score_error(a, b):
        return max(abs(x-y) for x, y in zip(a, b, strict=True))

    def save():
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2))

    def pair(label, messages, limit, greedy=False, seed=123, probe=False):
        values = []
        for engine, previous in [(old, old_uses_upstream_generation), (new, False)]:
            reset(engine, args.profile, previous)
            if greedy:
                with greedy_sampling(args.profile, args.compare):
                    values.append(run(engine, messages, limit, seed, probe=probe))
            else:
                values.append(run(engine, messages, limit, seed, probe=probe))
        a, b = values
        checks = {field:a[field]==b[field] for field in parity_fields}
        if probe:
            checks['first_logprobs_max_abs_error'] = score_error(a['scores'], b['scores'])
            a['scores'] = b['scores'] = None
        report['correctness'].append(dict(case=label, checks=checks, previous=a, still=b))
        save()
        print(json.dumps(dict(case=label,checks=checks)),flush=True)
        assert all(checks[k] for k in checks if k!='first_logprobs_max_abs_error'), label
        if probe:
            assert checks['first_logprobs_max_abs_error'] < .001, checks
        return b

    short = [{'role':'user','content':'Explain why a cache needs to match its token history. Give three practical examples.'}]
    math = [{'role':'user','content':'A notebook and a pen cost $11 together. The notebook costs $10 more than the pen. What does the pen cost? Think briefly and answer in one sentence.'}]
    long = [{'role':'user','content':('A useful question makes assumptions explicit and distinguishes evidence from inference. '*90)+'Summarize this in three short points.'}]
    medium = [{'role':'user','content':('A useful question makes assumptions explicit and distinguishes evidence from inference. '*30)+'Summarize this in three short points.'}]
    if args.mode in ('smoke','correctness','all'):
        pair('seeded-short', short, 64, probe=True)
        if args.mode!='smoke':
            pair('greedy-long', long, 96, greedy=True, probe=True)
            pair('unicode', [{'role':'user','content':'Briefly translate “curiosity” into Japanese and French, then add an emoji.'}], 192)
            reply = pair('reasoning-and-eos', math, 512, greedy=True)
            assert reply['finish']=='stop' and reply['answer'] and reply['reasoning']
            followup=math+[dict(role='assistant',content=reply['answer'],reasoning_content=reply['reasoning']),dict(role='user',content='Change the total to $13. Now what does the pen cost? Answer briefly.')]
            second=pair('second-turn-cold',followup,512,greedy=True)
            assert second['finish']=='stop' and second['answer'] and second['reasoning']

            # Compare like-for-like cached execution to the reference. Different
            # prefill shapes can change quantized arithmetic and reasoning text.
            warmed = []
            for name, engine, previous in [('previous', old, old_uses_upstream_generation), ('still', new, False)]:
                reset(engine, args.profile, previous)
                with greedy_sampling(args.profile, args.compare):
                    first=run(engine,math,512)
                    warm=run(engine,followup,512,probe=True)
                    reset(engine,args.profile,previous)
                    cold=run(engine,followup,512)
                equal=warm['tokens']==cold['tokens'] and warm['text']==cold['text']
                scores=warm.pop('scores')
                warmed.append((warm,scores))
                report['correctness'].append(dict(case='warm-vs-cold-'+name, cached_tokens=warm['cached_tokens'], tokens_equal=equal, answer_equal=warm['answer']==cold['answer'], warm=warm, cold=cold))
                save()
                assert warm['answer']==cold['answer']
                assert re.search(r'\$1\.50?\b', warm['answer']), warm['answer']
                if args.profile=='gemma12B':
                    assert equal, 'Gemma warm/cold parity'
                print('PASS warm/cold answers '+name+'; token equality='+str(equal),flush=True)
            a,b=warmed
            checks={field:a[0][field]==b[0][field] for field in parity_fields}
            checks['first_logprobs_max_abs_error']=score_error(a[1], b[1])
            report['correctness'].append(dict(case='cached-reference-parity',checks=checks))
            save()
            assert all(checks[k] for k in checks if k!='first_logprobs_max_abs_error')
            assert checks['first_logprobs_max_abs_error']<.001
            print(json.dumps(dict(case='cached-reference-parity',checks=checks)),flush=True)

            # A consumer disconnect must invalidate partial state and allow retry.
            reset(new,args.profile)
            prompt,tokens=new.prepare(short)
            gen=new.generate(prompt,tokens,64)
            next(gen);gen.close()
            assert (len(new.cache)==0 if args.profile=='inklingMini' else new.cache is None)
            retry=run(new,short,64)
            reset(new,args.profile)
            fresh=run(new,short,64)
            assert retry['tokens']==fresh['tokens']
            report['correctness'].append(dict(case='cancel-retry',passed=True))
            save()
            print('PASS cancel-retry',flush=True)

    if args.mode in ('performance','all'):
        # Warm each code path before measurements, then reverse order each pair.
        for engine in [old, new]:
            reset(old,args.profile,old_uses_upstream_generation)
            reset(new,args.profile,False)
            run(engine,short,24)
        for label,messages in [('short',short),('long',long),('warm-followup',long),('cached-followup',medium)]:
            if label not in args.cases:
                continue
            for iteration in range(args.pairs):
                order=[('previous',old,old_uses_upstream_generation),('still',new,False)]
                if iteration%2:order.reverse()
                for name,engine,previous in order:
                    reset(old,args.profile,old_uses_upstream_generation)
                    reset(new,args.profile,False)
                    measured_messages=messages
                    if label in ('warm-followup','cached-followup'):
                        first=run(engine,messages,64)
                        measured_messages=messages+[dict(role='assistant',content=first['answer'],reasoning_content=first['reasoning']),dict(role='user',content='Give a concrete example, briefly.')]
                    result=run(engine,measured_messages,args.tokens)
                    result.pop('scores')
                    report['measurements'].append(dict(case=label,iteration=iteration,implementation=name,**result))
                    save()
                    print(json.dumps(dict(case=label,iteration=iteration,implementation=name,seconds=result['seconds'],ttft=result['first_token_seconds'],tps=result['decode_tps'],peak_gb=result['peak_gb'])),flush=True)
        summary={}
        for label in args.cases:
            summary[label]={}
            for iteration in range(args.pairs):
                paired=[r for r in report['measurements'] if r['case']==label and r['iteration']==iteration]
                for field in parity_fields:
                    assert paired[0][field] == paired[1][field], (label, iteration, field)
                if extraction and label == 'warm-followup':
                    assert paired[0]['cached_tokens'] == 0, 'Expected fallback after sliding-window eviction'
                if extraction and label == 'cached-followup':
                    assert paired[0]['cached_tokens'] > 0, 'Expected prompt-prefix reuse'
            for name in ['previous','still']:
                rows=[r for r in report['measurements'] if r['case']==label and r['implementation']==name]
                summary[label][name]={k:statistics.median(r[k] for r in rows) for k in
                                      ['seconds','first_token_seconds','decode_tps','peak_gb','peak_extra_gb']}
        report['summary']=summary
        if args.max_slowdown is not None:
            report['performance_gate']={label: (
                values['still']['seconds'] <= values['previous']['seconds'] * args.max_slowdown
                and values['still']['decode_tps'] * args.max_slowdown >= values['previous']['decode_tps']
            ) for label,values in summary.items()}
        save()
        print(json.dumps(summary),flush=True)
        if args.max_slowdown is not None:
            assert all(report['performance_gate'].values()), report['performance_gate']


if __name__=='__main__':
    main()
