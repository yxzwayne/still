import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Resources'))
from gemma_protocol import GemmaDecoder


class GemmaProtocolTests(unittest.TestCase):
    raw = '<|channel>thought\nCompare 2 < 3 🌿.\n<channel|>The answer. <turn|>'

    def decode(self, chunks):
        decoder = GemmaDecoder()
        answer = reasoning = ''
        for chunk in chunks:
            a, r = decoder.feed(chunk)
            answer += a
            reasoning += r
        a, r = decoder.feed('', final=True)
        return answer + a, reasoning + r

    def test_all_splits_and_single_characters(self):
        expected = ('The answer. ', 'Compare 2 < 3 🌿.\n')
        for cut in range(len(self.raw) + 1):
            self.assertEqual(self.decode([self.raw[:cut], self.raw[cut:]]), expected)
        self.assertEqual(self.decode(list(self.raw)), expected)

    def test_plain_answer_and_literal_markup(self):
        self.assertEqual(self.decode(list('Hello **world**. <div>x</div>')), ('Hello **world**. <div>x</div>', ''))

    def test_truncated_reasoning_and_control_markers(self):
        self.assertEqual(self.decode(['<|channel>thought\nPartial<chan']), ('', 'Partial'))
        self.assertEqual(self.decode(['Answer <']), ('Answer <', ''))

    def test_empty_thought(self):
        self.assertEqual(self.decode(['<|channel>thought\n<channel|>Answer']), ('Answer', ''))
