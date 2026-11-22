"""Run the bundled HTTP server using a clean GemmaTextRuntime interpreter."""

import argparse
from importlib.util import find_spec
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
MODEL = Path.home() / 'Library/Application Support/Still/Models/gemma-4-12B-it-4bit'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, default=ROOT / 'dist/Still.app/Contents/Resources')
    args = parser.parse_args()
    for package in ('mlx_lm', 'mlx_vlm'):
        if find_spec(package) is not None:
            parser.error(f'{package} is installed. Use the standalone Gemma interpreter.')
    print('Neither upstream model library is installed.', flush=True)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]

    base = f'http://127.0.0.1:{port}'
    command = [
        sys.executable, '-E', '-s', '-B', str(args.resources / 'local_server.py'),
        '--parent-pid', str(os.getpid()), '--model', str(MODEL),
        '--port', str(port), '--profile', 'gemma12B',
    ]
    with subprocess.Popen(command, env={**os.environ, 'HF_HUB_OFFLINE': '1',
                                        'TOKENIZERS_PARALLELISM': 'false'}) as server:
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError(f'Still exited with code {server.returncode}.')
                try:
                    with urlopen(base + '/still/health', timeout=1) as response:
                        assert json.load(response)['model'] == str(MODEL)
                    break
                except URLError:
                    time.sleep(0.1)
            else:
                raise RuntimeError('Still never answered its health check.')

            def request(messages, stream=False):
                body = {'model': str(MODEL), 'messages': messages, 'max_completion_tokens': 512,
                        'stream': stream, 'stream_options': {'include_usage': True}}
                return urlopen(Request(base + '/v1/chat/completions', json.dumps(body).encode(),
                                       {'Content-Type': 'application/json'}), timeout=120)

            messages = [{'role': 'user', 'content': 'What is 12 plus 7? Think briefly and answer.'}]
            with request(messages) as response:
                completion = json.load(response)
            first = completion['choices'][0]['message']
            assert first['reasoning_content'] and '19' in first['content'], completion
            assert completion['usage']['completion_tokens'] > 0
            print('Nonstreaming reasoning and answer passed.', flush=True)

            messages += [first, {'role': 'user', 'content': 'Add two to that result.'}]
            with request(messages, stream=True) as response:
                events = [line[6:].strip() for line in response if line.startswith(b'data: ')]
            assert events.pop() == b'[DONE]'
            packets = [json.loads(event) for event in events]
            assert all('error' not in packet for packet in packets), packets
            choices = [choice for packet in packets for choice in packet['choices']]
            answer = ''.join(choice['delta'].get('content', '') for choice in choices)
            reasoning = ''.join(choice['delta'].get('reasoning_content', '') for choice in choices)
            assert '21' in answer and reasoning, (answer, reasoning)
            assert choices[-1]['finish_reason'] in {'stop', 'length'}
            assert packets[-1]['usage']['completion_tokens'] > 0
            print('Streaming follow-up, separate reasoning, finish reason and usage passed.', flush=True)

            try:
                with request([{'role': 'user', 'content': ' too long' * 7000}]):
                    raise AssertionError('Still accepted a prompt past the context budget.')
            except HTTPError as error:
                assert error.code == 400
                assert 'local memory budget' in json.load(error)['error']['message']
            print('Context budget rejection passed.', flush=True)
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == '__main__':
    main()
