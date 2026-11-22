import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Resources'))
from inkling_protocol import InklingDecoder


class InklingProtocolTests(unittest.TestCase):
    raw = ('<|message_model|><|content_thinking|>Compare 🌿 and 2 < 3.'
           '<|end_message|><|message_model|><|content_text|>Use **A**.'
           '<|end_message|><|content_model_end_sampling|>')

    def decode(self, chunks):
        decoder = InklingDecoder()
        answer, reasoning = '', ''
        for chunk in chunks:
            a, r = decoder.feed(chunk)
            self.assertNotIn('<|', a + r)
            answer += a
            reasoning += r
        a, r = decoder.feed('', final=True)
        return answer + a, reasoning + r

    def test_every_boundary_and_character(self):
        expected = ('Use **A**.', 'Compare 🌿 and 2 < 3.')
        for cut in range(len(self.raw) + 1):
            self.assertEqual(self.decode([self.raw[:cut], self.raw[cut:]]), expected)
        self.assertEqual(self.decode(list(self.raw)), expected)

    def test_alternating_channels(self):
        raw = '<|content_thinking|>First.<|content_text|>A.<|content_thinking|>Second.<|content_text|>B.'
        self.assertEqual(self.decode(list(raw)), ('A.B.', 'First.Second.'))

    def test_truncation_keeps_reasoning(self):
        self.assertEqual(self.decode(['<|content_thinking|>Partial<|end_mes']), ('', 'Partial'))
        self.assertEqual(self.decode(['<|content_text|>x <']), ('x <', ''))

    def test_unsupported_channels_are_not_answers(self):
        raw = '<|message_model|>toolname<|content_invoke_tool_json|>{"x":1}<|end_message|><|message_model|><|content_text|>Answer'
        self.assertEqual(self.decode(list(raw)), ('Answer', ''))

    def test_sse_normalization_and_request_isolation(self):
        decoder = InklingDecoder()
        answers, thoughts = [], []
        for char in self.raw:
            packet = {'choices': [{'delta': {'role': 'assistant', 'content': char}, 'finish_reason': None}]}
            normalized = decoder.normalize(packet, streaming=True)['choices'][0]['delta']
            answers.append(normalized.get('content', ''))
            thoughts.append(normalized.get('reasoning_content', ''))
        self.assertEqual(''.join(answers), 'Use **A**.')
        self.assertEqual(''.join(thoughts), 'Compare 🌿 and 2 < 3.')
        self.assertEqual(InklingDecoder().feed('<|content_text|>Fresh'), ('Fresh', ''))

    def test_nonstream_and_upstream_reasoning_alias(self):
        packet = {'choices': [{'message': {'content': self.raw, 'reasoning': 'Prelude. '}, 'finish_reason': 'stop'}]}
        message = InklingDecoder().normalize(packet, streaming=False)['choices'][0]['message']
        self.assertEqual(message, {'content': 'Use **A**.', 'reasoning_content': 'Prelude. Compare 🌿 and 2 < 3.'})


if __name__ == '__main__':
    unittest.main()
