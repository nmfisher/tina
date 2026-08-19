import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// [ScrollingTextRegion.snapshotLines] — the read-only window the maximize
/// overlay renders from: scrollback history followed by visible content rows,
/// oldest first, styled the way the region itself paints.
void main() {
  late FakeStdio io;
  late Screen screen;

  setUp(() {
    io = FakeStdio();
    screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24),
      ansi: AnsiCapable.yes,
    );
    screen.redrawFrame();
  });

  test('returns visible content rows, oldest first, without blanks', () {
    screen.chat.write('a\nb\nc');
    final lines = screen.chat.snapshotLines();
    expect(lines, ['a', 'b', 'c']);
  });

  test('includes rows that scrolled into history', () async {
    final h = screen.chat.bounds.height;
    for (var i = 0; i < h + 10; i++) {
      screen.chat.write('line $i\n');
    }
    final lines = screen.chat.snapshotLines();
    expect(lines.length, greaterThan(h));
    expect(lines.first, startsWith('line 0'));
    expect(lines.where((l) => l.startsWith('line ')).length, h + 10,
        reason: 'every written line is retained, none dropped');
  });

  test('snapshot does not disturb the region paint state', () {
    screen.chat.write('hello');
    screen.chat.snapshotLines();
    screen.chat.repaint();
    // No throw, and content is unchanged by snapshot+repaint.
    expect(screen.chat.snapshotLines(), ['hello']);
  });
}
