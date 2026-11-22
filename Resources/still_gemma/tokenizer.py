"""Gemma chat template and streaming decoder adapted from MLX-VLM. See LICENSE."""

import json
from pathlib import Path

from jinja2.sandbox import ImmutableSandboxedEnvironment
from tokenizers import Tokenizer


class ChatTokenizer:
    def __init__(self, path, config):
        path = Path(path)
        tokenizer_config = json.loads((path / 'tokenizer_config.json').read_text())
        generation_config = json.loads((path / 'generation_config.json').read_text())
        self.tokenizer = Tokenizer.from_file(str(path / 'tokenizer.json'))
        self.bos = tokenizer_config['bos_token']
        self.stop_ids = frozenset([
            *generation_config.get('eos_token_id', config['eos_token_id']),
            self.tokenizer.token_to_id(tokenizer_config['eos_token']),
        ])
        environment = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True)
        self.template = environment.from_string((path / 'chat_template.jinja').read_text())

        # The pinned tokenizer uses the SentencePiece decoder with no leading
        # space stripping. Build the lookup table once for all requests.
        self.tokens = [None] * self.tokenizer.get_vocab_size()
        for text, token in self.tokenizer.get_vocab().items():
            if len(text) == 6 and text.startswith('<0x') and text.endswith('>'):
                self.tokens[token] = int(text[3:5], 16)
            else:
                self.tokens[token] = text

    def prepare(self, messages):
        # Match the reference's typed text parts, including its template's
        # handling of a leading system message and assistant history.
        formatted = []
        for message in messages:
            text = message['content']
            content = (text if message['role'] == 'assistant'
                       else [{'type': 'text', 'text': text}])
            entry = {'role': message['role'], 'content': content}
            if 'reasoning_content' in message:
                entry['reasoning_content'] = message['reasoning_content']
            formatted.append(entry)
        prompt = self.template.render(
            messages=formatted, bos_token=self.bos, tools=None,
            enable_thinking=True, add_generation_prompt=True,
        )
        return prompt, self.tokenizer.encode(prompt, add_special_tokens=False).ids

    def detokenizer(self):
        return StreamingDetokenizer(self.tokens)


class StreamingDetokenizer:
    def __init__(self, tokens):
        self.tokens = tokens
        self.reset()

    def reset(self):
        self.text = ''
        self.pending = ''
        self.bytes = bytearray()
        self.offset = 0

    def _flush_bytes(self):
        if self.bytes:
            self.pending += self.bytes.decode('utf-8', errors='replace')
            self.bytes.clear()

    def add_token(self, token):
        value = self.tokens[token]
        if isinstance(value, int):
            self.bytes.append(value)
            return
        self._flush_bytes()
        if value.startswith('▁'):
            self.text += self.pending.replace('▁', ' ')
            self.pending = value
        else:
            self.pending += value

    def finalize(self):
        self._flush_bytes()
        self.text += self.pending.replace('▁', ' ')
        self.pending = ''

    @property
    def last_segment(self):
        if self.text.endswith('\ufffd'):
            return ''
        segment = self.text[self.offset:]
        self.offset = len(self.text)
        return segment
