"""Translate Inkling's serialized channels into the shared chat API fields."""


class InklingDecoder:
    def __init__(self):
        self.pending = ''
        self.channel = None

    def feed(self, text, *, final=False):
        self.pending += text
        answer, reasoning = [], []

        def emit(value):
            if self.channel == 'answer':
                answer.append(value)
            elif self.channel == 'reasoning':
                reasoning.append(value)

        while self.pending:
            start = self.pending.find('<|')
            if start < 0:
                tail = '<' if self.pending.endswith('<') and not final else ''
                emit(self.pending[:-1] if tail else self.pending)
                self.pending = tail
                break
            emit(self.pending[:start])
            self.pending = self.pending[start:]
            end = self.pending.find('|>')
            if end < 0:
                # A truncated control token must never become visible text.
                if final:
                    self.pending = ''
                break
            token, self.pending = self.pending[:end + 2], self.pending[end + 2:]
            if token == '<|content_thinking|>':
                self.channel = 'reasoning'
            elif token in ('<|content_text|>', '<|content_tool_error|>'):
                self.channel = 'answer'
            elif token in ('<|end_message|>', '<|message_model|>', '<|content_model_end_sampling|>'):
                self.channel = None
            elif token.startswith('<|content_') or token.startswith('<|message_'):
                # Unsupported tool/media channels are not chat text.
                self.channel = None
        return ''.join(answer), ''.join(reasoning)

    def normalize(self, response, *, streaming):
        """Normalize each packet before MLX serializes it to HTTP/SSE."""
        for choice in response.get('choices', []):
            message = choice.get('delta' if streaming else 'message')
            if message is None:
                continue
            answer, reasoning = self.feed(
                message.get('content') or '',
                final=not streaming or choice.get('finish_reason') is not None,
            )
            # Preserve already-separated reasoning if upstream supplies any.
            reasoning = (message.pop('reasoning', None) or message.get('reasoning_content') or '') + reasoning
            message.pop('content', None)
            message.pop('reasoning_content', None)
            if answer or not streaming:
                message['content'] = answer
            if reasoning:
                message['reasoning_content'] = reasoning
        return response
