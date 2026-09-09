import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// The dedicated error section beneath the input box: the bottom border row
/// renders the latest warning/error notice, then restores the border on
/// clear. See Screen.setErrorStrip / clearErrorStrip.
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

  test('error strip renders on the bottom border row; corners intact', () {
    screen.setErrorStrip('provider error: 502 — retry 1/3 in 0.8s',
        error: true);
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.bottomBorderRow);
    expect(row, contains('provider error: 502'));
    expect(row, contains('└'), reason: 'corner glyphs stay');
    expect(row, contains('┘'));
  });

  test('a newer notice replaces the text', () {
    screen.setErrorStrip('first failure', error: true);
    screen.setErrorStrip('second warning — retry 2/3', error: false);
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.bottomBorderRow);
    expect(row, contains('second warning — retry 2/3'));
    expect(row, isNot(contains('first failure')),
        reason: 'the strip shows the LATEST notice only');
  });

  test('clear restores the border line', () {
    screen.setErrorStrip('transient', error: true);
    screen.clearErrorStrip();
    vt.feed(io.written.toString());
    final row = vt.rowText(layout.bottomBorderRow);
    expect(row, contains('─'), reason: 'the border line returns');
    expect(row, isNot(contains('transient')));
  });

  test('multi-line notice text collapses to one strip line', () {
    screen.setErrorStrip('line one\nline two', error: true);
    vt.feed(io.written.toString());
    expect(vt.rowText(layout.bottomBorderRow), contains('line one line two'));
  });
}
