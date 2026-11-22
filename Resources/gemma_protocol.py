"""Gemma channel framing; the native chat client only sees structured fields."""


class GemmaDecoder:
    markers = {
        '<|channel>thought\n': 'reasoning',
        '<channel|>': 'answer',
        '<|turn>model\n': 'answer',
        '<turn|>': None,
        '<eos>': None,
        '<|endoftext|>': None,
    }

    def __init__(self):
        self.pending = ''
        self.channel = 'answer'

    def feed(self, text, *, final=False):
        self.pending += text
        answer, reasoning = [], []
        while self.pending:
            marker = next((m for m in self.markers if self.pending.startswith(m)), None)
            if marker is not None:
                self.channel = self.markers[marker]
                self.pending = self.pending[len(marker):]
                continue
            if any(m.startswith(self.pending) for m in self.markers):
                if not final:
                    break
                if len(self.pending) > 1:
                    self.pending = ''
                    break
            if self.channel == 'answer':
                answer.append(self.pending[0])
            elif self.channel == 'reasoning':
                reasoning.append(self.pending[0])
            self.pending = self.pending[1:]
        return ''.join(answer), ''.join(reasoning)
