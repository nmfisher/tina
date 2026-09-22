import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Permission mode and plugin status share the strip beneath the input row.
void main() {
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;
  late ScreenLayout layout;

  setUp(() {
    io = FakeStdio();
    layout = ScreenLayout.fromSize(100, 24);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  test('plugin status survives redraw and clearing preserves the mode', () {
    screen.setModeLabel('mode: auto');
    screen.setStatusLines(const [
      RenderLine(runs: [RenderRun('Last input: git push', null)])
    ]);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('mode: auto'));
    expect(row, contains('Last input: git push'));
    screen.setStatusLines(const []);
    vt.feed(io.written.toString());
    expect(vt.rowText(layout.stripRow), isNot(contains('git push')));
    expect(vt.rowText(layout.stripRow), contains('mode: auto'));
  });

  test('plugin status is clipped and cannot inject terminal controls', () {
    screen.setStatusLines([
      RenderLine(runs: [RenderRun('status\n\x1b[2J${'x' * 200}', null)])
    ]);
    vt.feed(io.written.toString());
    expect(vt.rowText(layout.stripRow), contains('status'));
    expect(vt.charAt(layout.stripRow, 99), ' ');
    expect(vt.rowText(layout.bottomBorderRow), contains('└'));
  });

  test('a mode-label update repaints the strip in place', () {
    screen.setModeLabel('mode: ask');
    screen.setModeLabel('mode: auto');
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('mode: auto'));
    expect(row, isNot(contains('mode: ask')));
  });
}
