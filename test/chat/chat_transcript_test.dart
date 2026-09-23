import 'package:test/test.dart';
import 'package:tina/chat/chat_transcript.dart';
import 'package:tina/chat/markdown_renderer.dart';
import 'package:tina_console/tina_console.dart';

/// The rendered text of a transcript, one visual line per row, with the
/// trailing padding removed so a golden reads as the user sees it.
String _render(List<ChatBlock> blocks, {int width = 60}) {
  final lines = renderTranscript(blocks, width: width);
  final out = <String>[];
  for (final line in lines) {
    if (line.isBlank) {
      out.add('');
      continue;
    }
    out.add(line.runs.map((r) => r.text).join().trimRight());
  }
  return out.join('\n');
}

/// Every rendered line must fit the requested width — the region wraps
/// anything wider, which would push content past the panel edge.
void _expectFits(String rendered, int width) {
  for (final line in rendered.split('\n')) {
    expect(plainWidth(line), lessThanOrEqualTo(width),
        reason: 'overflows $width columns: "$line"');
  }
}

const _main = ChatSpeaker(id: 'c1', label: 'main');

void main() {
  group('block kinds', () {
    test('only reasoning and tool calls fold, and they start folded', () {
      expect(ChatBlockKind.user.canFold, isFalse);
      expect(ChatBlockKind.prose.canFold, isFalse);
      expect(ChatBlockKind.notice.canFold, isFalse);
      expect(ChatBlockKind.reasoning.canFold, isTrue);
      expect(ChatBlockKind.toolCall.canFold, isTrue);
      expect(ChatBlockKind.reasoning.startsFolded, isTrue);
      expect(ChatBlockKind.toolCall.startsFolded, isTrue);
    });

    test('a tool call with no retained output cannot be folded', () {
      final block = ChatBlock.toolCall(_main, subject: 'bash · ls');
      expect(block.canFold, isFalse,
          reason: 'there is nothing behind the header to reveal');
    });

    test('a notice carries severity as a word, not a glyph', () {
      final rendered = _render([
        ChatBlock.notice(_main, 'retrying after a 502', notice: 'warn'),
      ]);
      expect(rendered, ' warn · retrying after a 502');
    });
  });

  group('rendering', () {
    test('rows carry no speaker prefix — one margin column only', () {
      final rendered = _render([
        ChatBlock.user('why is CI red?'),
        ChatBlock.prose(_main, [
          MarkdownLine(runs: [MarkdownRun('Looking at the failing job.', null)]),
        ]),
      ]);
      expect(rendered, '''
 why is CI red?

 Looking at the failing job.''');
      expect(rendered, isNot(contains('│')));
      expect(rendered, isNot(contains('main')));
    });

    test('a folded tool call is one line: glyph, subject, status', () {
      final rendered = _render([
        ChatBlock.toolCall(_main,
            subject: 'bash · grep -rn flake test/ | head -20',
            status: 'ok · 41ms',
            body: plainLines('test/a_test.dart:12: flake')),
      ]);
      expect(rendered,
          ' → bash · grep -rn flake test/ | head -20  ok · 41ms');
    });

    test('an expanded tool call nests its output under the header', () {
      final block = ChatBlock.toolCall(_main,
          subject: 'bash · dart test',
          status: 'failed · 1.4s',
          body: plainLines('00:01 +0 -1: rejectsBareColon [E]\n'
              'Expected: <true>'));
      block.folded = false;
      final rendered = _render([block]);
      expect(rendered, '''
 → bash · dart test  failed · 1.4s
   00:01 +0 -1: rejectsBareColon [E]
   Expected: <true>''');
    });

    test('reasoning is a count until expanded', () {
      final block = ChatBlock.reasoning(_main, 'x' * 412);
      expect(_render([block]), ' ▸ reasoning  412 chars');

      block.folded = false;
      final expanded = _render([block]);
      final lines = expanded.split('\n');
      expect(lines.first, ' ▾ reasoning  412 chars');
      expect(lines.length, greaterThan(1),
          reason: 'the text is revealed, not summarised');
      for (final line in lines.skip(1)) {
        expect(line, startsWith(kNestedPrefix),
            reason: 'revealed text nests under its header');
      }
      // Nothing is lost in the wrap, and no line overflows.
      expect('x'.allMatches(expanded).length, 412);
      _expectFits(expanded, 60);
    });

    test('the folded count tracks the text, so it cannot lie', () {
      expect(_render([ChatBlock.reasoning(_main, 'abcde')]),
          ' ▸ reasoning  5 chars');
    });

    test('a partial reasoning block says so', () {
      final rendered = _render(
          [ChatBlock.reasoning(_main, 'half a thought', complete: false)]);
      expect(rendered, contains('reasoning (partial)'));
    });
  });

  group('wrapping', () {
    test('a long paragraph wraps under the shared margin', () {
      final rendered = _render([
        ChatBlock.prose(_main, [
          MarkdownLine(runs: [
            MarkdownRun(
                'The failure is a flake in ParserTest.rejectsBareColon, '
                    'not a real regression, and two things point that way.',
                null),
          ]),
        ]),
      ], width: 40);
      _expectFits(rendered, 40);
      final lines = rendered.split('\n');
      expect(lines.length, greaterThan(1));
      for (final line in lines) {
        expect(line, startsWith(kMargin),
            reason: 'every row keeps the one-column margin');
      }
    });

    test('words survive a wrap — no mid-word breaks in prose', () {
      final rendered = _render([
        ChatBlock.prose(_main, [
          MarkdownLine(runs: [
            MarkdownRun('alpha beta gamma delta epsilon zeta eta theta', null),
          ]),
        ]),
      ], width: 24);
      expect(rendered, isNot(contains('alp\n')));
      for (final word in [
        'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta',
      ]) {
        expect(rendered, contains(word), reason: '$word was broken');
      }
    });

    test('the user message wraps under the shared margin', () {
      final rendered = _render([
        ChatBlock.user('a message long enough that it cannot possibly fit on '
            'one single line of this transcript at all'),
      ], width: 40);
      _expectFits(rendered, 40);
      expect(rendered.split('\n').first, startsWith(kMargin));
      expect(rendered.split('\n')[1], startsWith(kMargin));
    });

    test('a code block wraps hard and keeps its bar', () {
      final lines = renderTranscript([
        ChatBlock.prose(_main, [
          MarkdownLine(bar: '100', runs: [
            MarkdownRun('final p = await parse(source); expect(ok);', null),
          ]),
        ]),
      ], width: 30);
      for (final line in lines) {
        expect(plainWidth(line.runs.map((r) => r.text).join()),
            lessThanOrEqualTo(30));
        if (line.runs.isNotEmpty) expect(line.bar, '100');
      }
    });

    test('a single word longer than the line is broken, not overflowed', () {
      final rendered = _render([
        ChatBlock.prose(_main, [
          MarkdownLine(runs: [MarkdownRun('x' * 100, null)]),
        ]),
      ], width: 30);
      _expectFits(rendered, 30);
      expect(rendered, contains('xxxx'));
    });

    test('wide glyphs are counted in cells, not code units', () {
      // Each CJK glyph is one code unit but two cells; a width that fits by
      // code units would overflow on the real terminal (tin-q4vz).
      final rendered = _render([
        ChatBlock.prose(_main, [
          MarkdownLine(runs: [MarkdownRun('漢' * 20, null)]),
        ]),
      ], width: 30);
      _expectFits(rendered, 30);
    });

    test('a transcript too narrow for even the margin degrades to plain text',
        () {
      final rendered = _render([
        ChatBlock.user('hello'),
      ], width: 1);
      expect(rendered, 'hello');
    });
  });

  group('shapes the host relies on', () {
    test('blank lines between blocks carry no prefix', () {
      final lines = renderTranscript([
        ChatBlock.user('one'),
        ChatBlock.user('two'),
      ], width: 40);
      final blanks = lines.where((l) => l.isBlank).toList();
      expect(blanks, hasLength(1));
      expect(blanks.single.runs, isEmpty);
    });

    test('a trailing blank is never emitted', () {
      final lines = renderTranscript([
        ChatBlock.user('one'),
      ], width: 40);
      expect(lines.last.isBlank, isFalse);
    });
  });
}
