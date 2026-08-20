import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// A first-refresh hide must not erase the info column: on a resumed session
/// with restored spawned panels, the session bar's InfoPanel is hidden by its
/// very first refresh (side panels own the column) without ever having
/// rendered. Its hide() used to blank the whole info rect regardless — wiping
/// the just-restored panel borders until focus cycling repainted them.
void main() {
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;

  setUp(() {
    io = FakeStdio()..columns = 100;
    final layout =
        ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  PanelFrame _spawnedPanel() {
    final frame = PanelFrame(screen: screen, label: 'scout', conversationId: 'c1')
      ..setReservesInput(true);
    frame.setOuter(Rect(
      row: screen.layout.topBorderRow,
      col: screen.layout.infoLeftCol,
      width: screen.layout.info.width,
      height: screen.layout.bottomBorderRow - screen.layout.topBorderRow + 1,
    ));
    return frame;
  }

  test('hide() before any render leaves spawned panel borders intact', () {
    final frame = _spawnedPanel();
    vt.feed(io.written.toString());
    io.written.clear();
    // The panel's left border column, mid-height.
    final borderRow = (frame.bounds.row + frame.bounds.bottom) ~/ 2;
    final borderCol = frame.bounds.col;
    expect(vt.charAt(borderRow, borderCol), '│',
        reason: 'sanity: the panel border is on screen');

    // The session-bar pattern: hidden by its FIRST refresh, never rendered.
    final bar = InfoPanel(screen, title: 'sessions');
    bar.hide();
    screen.refresh();
    vt.feed(io.written.toString());

    expect(vt.charAt(borderRow, borderCol), '│',
        reason: 'a never-rendered panel must not erase pixels that restored '
            'panels already own');
    expect(vt.charAt(frame.bounds.row, frame.bounds.col), '┌');
    expect(vt.charAt(frame.bounds.bottom, frame.bounds.col), '└');
  });

  test('hide() after rendering still clears the info column', () {
    final frame = _spawnedPanel();
    final bar = InfoPanel(screen, title: 'sessions');
    bar.setContent(const ['one', 'two']);
    vt.feed(io.written.toString());
    io.written.clear();

    final borderRow = (frame.bounds.row + frame.bounds.bottom) ~/ 2;
    bar.hide();
    screen.refresh();
    vt.feed(io.written.toString());

    // The bar DID paint, so hiding must blank its interior.
    expect(vt.charAt(borderRow, screen.layout.info.col), ' ');
  });

  test('hide() → show() round-trip still repaints content', () {
    final bar = InfoPanel(screen, title: 'sessions');
    bar.setContent(const ['hello']);
    bar.hide();
    bar.show();
    screen.refresh();
    vt.feed(io.written.toString());
    expect(vt.rowText(screen.layout.info.row + 1).contains('hello'), isTrue);
  });
}
