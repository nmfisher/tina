// B4: the two estimators, pinned. Different inputs, different formulas,
// different roundings — on purpose. These pins turn a silent drift between
// the context budget's gauge and the compaction trigger into a red test,
// and document the difference with the numbers they assert.
library;

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

Message text(String value, [bool synth = false]) =>
    Message(role: Role.user, content: [TextBlock(value)], isSynthetic: synth);

void main() {
  group('estimateRequestTokensUtf8 (context budget gauge)', () {
    test('UTF-8 bytes / 4, ceil — multibyte counts its bytes', () {
      expect(estimateRequestTokensUtf8(''), 0);
      expect(estimateRequestTokensUtf8('abcd'), 1, reason: '4 bytes / 4 = 1');
      expect(estimateRequestTokensUtf8('abcde'), 2,
          reason: '5 bytes / 4 = 1.25, ceil = 2');
      // é is two UTF-8 bytes; 5 characters but 10 bytes.
      expect(estimateRequestTokensUtf8('ééééé'), 3, reason: '10 bytes / 4 = 2.5, ceil = 3');
    });
  });

  group('estimateTranscriptTokensChars (compaction trigger)', () {
    test('chars / 4, floor — characters, not bytes', () {
      expect(estimateTranscriptTokensChars('', const []), 0);
      expect(estimateTranscriptTokensChars('abcd', const []), 1);
      // 5 characters is 1.25 tokens, floor = 1 — ceil on the same input
      // would say 2. This asymmetry is deliberate and pinned.
      expect(estimateTranscriptTokensChars('abcde', const []), 1);
      // é is ONE character here: 5 chars / 4 = 1 — the byte gauge on the
      // same string says 2.
      expect(estimateTranscriptTokensChars('ééééé', const []), 1);
    });

    test('counts text blocks, tool results and reasoning; skips tool calls',
        () {
      final messages = [
        Message(
          role: Role.user,
          content: const [
            TextBlock('question'),
            ToolResultBlock(toolUseId: 't1', content: 'result'),
          ],
        ),
        Message(
          role: Role.assistant,
          content: const [
            ToolUseBlock(id: 't1', name: 'tool', input: {'a': 'b'}),
          ],
          reasoning: const [ReasoningBlock('thinking')],
        ),
      ];
      // system 'sys' (3) + 'question' (8) + 'result' (6) + 'thinking' (8)
      // = 25 chars; the tool call's input JSON contributes nothing.
      expect(estimateTranscriptTokensChars('sys', messages), 6);
    });

    test('the byte gauge and the char gauge disagree by design', () {
      const request = 'ééééé';
      // Bytes: 10 -> ceil(2.5) = 3. Characters: 5 -> floor(1.25) = 1.
      expect(estimateRequestTokensUtf8(request), 3);
      expect(estimateTranscriptTokensChars(request, const []), 1);
    });
  });
}
