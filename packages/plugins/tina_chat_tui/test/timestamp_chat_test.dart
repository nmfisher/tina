import 'package:test/test.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/tina_console.dart';

void main() {
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
}
