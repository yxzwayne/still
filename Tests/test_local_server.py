import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request


class LocalServerTests(unittest.TestCase):
    def setUp(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        self.base = f'http://127.0.0.1:{self.port}'
        resources = Path(__file__).resolve().parents[1] / 'Resources'
        # Exercise our real HTTP boundary with deterministic model computation.
        bootstrap = '''
import sys, types, runpy
sys.path.insert(0, sys.argv[1])
from gemma_protocol import GemmaDecoder
class Engine:
 title='Fixture'; prompt_limit=30; context_limit=50; decoder=GemmaDecoder
 def __init__(self,path): pass
 def prepare(self,messages):
  return None,list(range(sum(len(m['content']) for m in messages)))
 def generate(self,prompt,tokens,limit):
  for i,text in enumerate(['<|channel>thought\\nCheck.', '<channel|>Answer.', '<turn|>']):
   yield types.SimpleNamespace(text=text,generation_tokens=i+1,finish_reason='stop' if i==2 else None)
sys.modules['model_engines']=types.SimpleNamespace(ENGINES={'gemma12B':Engine})
script=sys.argv.pop(1)+'/local_server.py'
runpy.run_path(script,run_name='__main__')
'''
        self.process = subprocess.Popen([sys.executable, '-c', bootstrap, str(resources), '--profile', 'gemma12B', '--parent-pid', str(os.getpid()), '--port', str(self.port), '--model', 'fixture'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                urllib.request.urlopen(self.base + '/still/health', timeout=1).close()
                return
            except OSError:
                time.sleep(.02)
        self.tearDown()
        self.fail('Server did not start')

    def tearDown(self):
        self.process.terminate()
        self.process.wait(timeout=5)

    def request(self, body, headers=None):
        return urllib.request.urlopen(urllib.request.Request(self.base + '/v1/chat/completions', json.dumps(body).encode(), headers or {'Content-Type': 'application/json'}), timeout=5)

    def test_structured_stream_and_nonstream(self):
        body = {'model': 'fixture', 'messages': [{'role': 'user', 'content': 'Hi'}]}
        with self.request(body) as response:
            message = json.load(response)['choices'][0]['message']
        self.assertEqual(message['content'], 'Answer.')
        self.assertEqual(message['reasoning_content'], 'Check.')
        body.update(stream=True, stream_options={'include_usage': True})
        with self.request(body) as response:
            lines = response.read().decode().splitlines()
        events = [json.loads(line[6:]) for line in lines if line.startswith('data: {')]
        self.assertIn('data: [DONE]', lines)
        self.assertEqual(events[-1]['usage']['completion_tokens'], 3)
        self.assertEqual(''.join(e['choices'][0]['delta'].get('reasoning_content', '') for e in events if e['choices']), 'Check.')

    def test_validation_and_context_limit(self):
        base = {'model': 'fixture', 'messages': [{'role': 'user', 'content': 'Hi'}]}
        cases = [dict(base, model='unknown'), dict(base, stream='yes'), dict(base, max_completion_tokens=0), dict(base, tools=[{}]), dict(base, stream_options=1), dict(base, messages=[{'role':'user','content':'x','reasoning_content':'bad'}]), dict(base, messages=[{'role':'user','content':'x'*31}])]
        for body in cases:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.request(body)
            self.assertEqual(error.exception.code, 400)
            self.assertTrue(json.load(error.exception)['error']['message'])

    def test_cross_site_and_content_type(self):
        for headers, status in [({'Content-Type':'text/plain'},415), ({'Content-Type':'application/json','Origin':'https://example.com'},403)]:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.request({}, headers)
            self.assertEqual(error.exception.code,status)


if __name__ == '__main__':
    unittest.main()
