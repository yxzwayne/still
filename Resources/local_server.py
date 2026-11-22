"""Still-owned local chat server. MLX libraries supply model computations only."""
import argparse
import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.dont_write_bytecode = True
from model_engines import ENGINES

parser = argparse.ArgumentParser()
parser.add_argument('--parent-pid', type=int, required=True)
parser.add_argument('--model', required=True)
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--profile', choices=ENGINES, required=True)
args = parser.parse_args()


def watch_parent():
    while True:
        time.sleep(2)
        if os.getppid() != args.parent_pid:
            os._exit(0)


threading.Thread(target=watch_parent, daemon=True).start()
engine = None


class Handler(BaseHTTPRequestHandler):
    # One request at a time also keeps all MLX work on the same thread.
    def log_message(self, *_):
        pass

    def send_json(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == '/still/health':
            self.send_json(200, {'app': 'Still', 'parent_pid': args.parent_pid, 'model': args.model})
        elif self.path == '/v1/models':
            self.send_json(200, {'data': [{'id': args.model, 'object': 'model'}]})
        else:
            self.send_json(404, {'error': {'message': 'Unknown endpoint'}})

    def do_POST(self):
        global engine
        if self.headers.get('Origin') not in (None, f'http://127.0.0.1:{args.port}'):
            return self.send_json(403, {'error': {'message': 'Requests from other websites are not allowed.'}})
        if self.headers.get_content_type() != 'application/json':
            return self.send_json(415, {'error': {'message': 'Send application/json.'}})
        if self.path != '/v1/chat/completions':
            return self.send_json(404, {'error': {'message': 'Unknown endpoint'}})
        started = False
        generation = None
        try:
            size = int(self.headers.get('Content-Length', 0))
            if not 0 < size <= 1_000_000:
                raise ValueError('The request is missing or too large.')
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict) or body.get('model') not in (args.model, 'default_model'):
                raise ValueError('This server only runs the configured model.')
            messages = body.get('messages')
            if not isinstance(messages, list) or not messages:
                raise ValueError('Send a nonempty messages array.')
            for message in messages:
                if not isinstance(message, dict) or message.get('role') not in ('system', 'user', 'assistant') or not isinstance(message.get('content'), str):
                    raise ValueError('This version of Still supports text chat.')
                thought = message.get('reasoning_content')
                if thought is not None and (not isinstance(thought, str) or message['role'] != 'assistant'):
                    raise ValueError('reasoning_content must be text on an assistant message.')
                if message.get('tool_calls'):
                    raise ValueError('Tool execution is not supported.')
            if body.get('tools'):
                raise ValueError('Tool execution is not supported.')
            limit = body.get('max_completion_tokens', body.get('max_tokens', 2048))
            if type(limit) is not int or limit < 1:
                raise ValueError('The output limit must be a positive integer.')
            streaming = body.get('stream', False)
            if type(streaming) is not bool:
                raise ValueError('stream must be a boolean.')
            options = body.get('stream_options') or {}
            if not isinstance(options, dict):
                raise ValueError('stream_options must be an object.')

            if engine is None:
                engine = ENGINES[args.profile](args.model)
            prompt, tokens = engine.prepare(messages)
            if len(tokens) > engine.prompt_limit:
                raise ValueError(f'This conversation has reached {engine.title}’s local memory budget. Start a new chat; this conversation is saved.')
            limit = min(limit, 2048, engine.context_limit - len(tokens))
            decoder = engine.decoder()
            request_id = 'chatcmpl-' + uuid.uuid4().hex
            created = int(time.time())

            def packet(answer='', reasoning='', finish=None):
                content = {}
                if answer:
                    content['content'] = answer
                if reasoning:
                    content['reasoning_content'] = reasoning
                return {'id': request_id, 'object': 'chat.completion.chunk', 'model': args.model, 'created': created,
                        'choices': [{'index': 0, 'delta': content, 'finish_reason': finish}]}

            def event(value):
                self.wfile.write(('data: ' + json.dumps(value) + '\n\n').encode())
                self.wfile.flush()

            if streaming:
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                started = True
            answer = reasoning = ''
            generated = 0
            finish = 'stop'
            # Token IDs used for budgeting are the same ones sent to the engine.
            generation = engine.generate(prompt, tokens, limit)
            for result in generation:
                a, r = decoder.feed(result.text)
                answer += a
                reasoning += r
                generated = result.generation_tokens
                if result.finish_reason:
                    finish = result.finish_reason
                if streaming and (a or r):
                    event(packet(a, r))
            a, r = decoder.feed('', final=True)
            answer += a
            reasoning += r
            usage = {'prompt_tokens': len(tokens), 'completion_tokens': generated, 'total_tokens': len(tokens) + generated}
            if streaming:
                event(packet(a, r, finish))
                if options.get('include_usage'):
                    event({'choices': [], 'usage': usage})
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            else:
                self.send_json(200, {'id': request_id, 'object': 'chat.completion', 'model': args.model, 'created': created,
                    'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': answer, 'reasoning_content': reasoning}, 'finish_reason': finish}], 'usage': usage})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            # Return a useful error without logging prompts or reasoning.
            if started:
                try:
                    event({'error': {'message': str(error)}})
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
                self.send_json(400 if isinstance(error, (ValueError, TypeError)) else 500, {'error': {'message': str(error)}})
        finally:
            if generation is not None:
                generation.close()


HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
