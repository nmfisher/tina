import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// The dedicated strip beneath the input row renders the latest notice,
/// independently of the bottom border. See Screen.setErrorStrip / clearErrorStrip.
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

  test('error strip renders above the bottom border; corners intact', () {
    screen.setErrorStrip('provider error: 502 — retry 1/3 in 0.8s',
        error: true);
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('provider error: 502'));
    expect(vt.rowText(layout.bottomBorderRow), contains('└'));
    expect(vt.rowText(layout.bottomBorderRow), contains('┘'));
  });

  test('a newer notice replaces the text', () {
    screen.setErrorStrip('first failure', error: true);
    screen.setErrorStrip('second warning — retry 2/3', error: false);
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('second warning — retry 2/3'));
    expect(row, isNot(contains('first failure')),
        reason: 'the strip shows the LATEST notice only');
  });

  test('clear removes the notice and preserves the border', () {
    screen.setErrorStrip('transient', error: true);
    screen.clearErrorStrip();
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(vt.rowText(layout.bottomBorderRow), contains('─'));
    expect(row, isNot(contains('transient')));
  });

  test('multi-line notice text collapses to one strip line', () {
    screen.setErrorStrip('line one\nline two', error: true);
    vt.feed(io.written.toString());
    expect(vt.rowText(layout.stripRow), contains('line one line two'));
  });

  test('the mode label renders and survives error clear', () {
    screen.setModeLabel('mode: auto');
    screen.setErrorStrip('provider error: 502', error: true);
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.stripRow);
    expect(row, contains('mode: auto'));
    expect(row, contains('provider error: 502'));

    screen.clearErrorStrip();
    vt.feed(io.written.toString());
    final after = vt.rowText(layout.stripRow);
    expect(after, contains('mode: auto'),
        reason: 'the mode label is the always-visible part of the strip');
    expect(after, isNot(contains('provider error')),
        reason: 'the status text is gone');
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
