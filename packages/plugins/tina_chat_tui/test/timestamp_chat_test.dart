import 'package:test/test.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/tina_console.dart';

void main() {
  test('stamps appear only on sender or calendar-minute changes', () {
    final renderer = TimestampChatRenderer(now: () => DateTime(2026));
    const agent = ChatSpeaker(id: 'agent', label: 'main');
    final blocks = [
      ChatBlock.user('first'),
      ChatBlock.user('same sender'),
      ChatBlock.notice(agent, 'agent reply'),
      ChatBlock.notice(agent, 'tool output'),
      ChatBlock.notice(agent, 'next minute'),
      ChatBlock.user('user reply'),
    ];
    final times = [
      DateTime(2026, 9, 30, 12, 0, 1),
      DateTime(2026, 9, 30, 12, 0, 59),
      DateTime(2026, 9, 30, 12, 0, 59),
      DateTime(2026, 9, 30, 12, 0, 59),
      DateTime(2026, 9, 30, 12, 1),
      DateTime(2026, 9, 30, 12, 1),
    ];
    for (var i = 0; i < blocks.length; i++) renderer.stamp(blocks[i], times[i]);
    renderer.group(blocks);
    String gutter(ChatBlock block) => renderer
        .render(block, RenderContext(width: 80, theme: const Theme.defaults()))
        .first
        .runs
        .first
        .text;
    expect(blocks.map(gutter),
        ['12:00 ', '      ', '12:00 ', '      ', '12:01 ', '12:01 ']);
    renderer.group([blocks[0], blocks[3]]);
    expect(gutter(blocks[3]), '12:00 ');
  });

  test('minute timestamps and hanging gutters preserve wrapped content', () {
    final block = ChatBlock.user('one two three four five six\nnext line');
    final renderer =
        TimestampChatRenderer(now: () => DateTime(2026, 9, 30, 3, 4, 59));
    for (final width in [18, 30, 80]) {
      final context =
          RenderContext(width: width, theme: const Theme.defaults());
      final plain = const ChatRenderer().render(
          block,
          RenderContext(
              width: width - TimestampChatRenderer.stampWidth,
              theme: context.theme));
      final rows = renderer.render(block, context);
      expect(rows.length, plain.length);
      var first = true;
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        if (plain[i].isBlank) {
          expect(row.isBlank, isTrue);
          continue;
        }
        expect(row.runs.first.text, first ? '03:04 ' : '      ');
        expect(row.runs.skip(1).map((r) => r.text).join(),
            plain[i].runs.map((r) => r.text).join());
        expect(visibleWidth(row.runs.map((r) => r.text).join()),
            lessThanOrEqualTo(width));
        first = false;
      }
      expect(first, isFalse);
    }
  });

  test('source breaks and tabs become bounded rows before gutters are added',
      () {
    final renderer =
        TimestampChatRenderer(now: () => DateTime(2026, 9, 30, 3, 4));
    final block = ChatBlock.user('first\nSECOND\r\nTHIRD\n\ttabbed');
    final rows = renderer.render(
        block, const RenderContext(width: 30, theme: Theme.defaults()));
    final text = rows.map((row) => row.runs.map((r) => r.text).join()).toList();
    expect(text,
        ['03:04  first', '       SECOND', '       THIRD', '           tabbed']);
    for (final row in text) {
      expect(row, isNot(contains(RegExp(r'[\r\n\t]'))));
      expect(plainWidth(row), lessThanOrEqualTo(30));
    }
  });
}
