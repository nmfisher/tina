import 'package:tina/tui/panel_maximize.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// Drives [runMaximizedPanelOverlay] with canned [InputEvent]s against a
/// Screen over [FakeStdio]. The overlay is read-only, so the observable
/// behavior is: it terminates on the close keys, and [onClosed] fires exactly
/// once (the ANSI-repaint hook).
void main() {
  test('ctrl+o closes the overlay', () async {
    final screen = fakeScreen();
    var closed = 0;
    await runMaximizedPanelOverlay(
      screen: screen,
      editor: LineEditor(screen: screen),
      title: 'agent',
      chat: screen.chat,
      readEvent: () async => ControlKey(ControlCode.ctrlO),
      onClosed: () => closed++,
    ).timeout(overlayTimeout);
    expect(closed, 1);
  });

  test('esc closes the overlay', () async {
    final screen = fakeScreen();
    var closed = 0;
    await runMaximizedPanelOverlay(
      screen: screen,
      editor: LineEditor(screen: screen),
      title: 'agent',
      chat: screen.chat,
      readEvent: () async => EscapeKey(),
      onClosed: () => closed++,
    ).timeout(overlayTimeout);
    expect(closed, 1);
  });

  test('scroll keys pan the view; only a close key terminates', () async {
    final screen = fakeScreen();
    for (var i = 0; i < 40; i++) {
      screen.chat.write('line $i\n');
    }
    final events = <InputEvent>[
      ArrowKey(ArrowDirection.pageUp),
      ArrowKey(ArrowDirection.up),
      ArrowKey(ArrowDirection.down),
      ControlKey(ControlCode.ctrlC),
    ];
    var i = 0;
    await runMaximizedPanelOverlay(
      screen: screen,
      editor: LineEditor(screen: screen),
      title: 'agent',
      chat: screen.chat,
      readEvent: () async => events[i++],
    ).timeout(overlayTimeout);
    expect(i, 4, reason: 'every scroll key is consumed, ctrlC closes');
  });

  test('an empty transcript renders and closes', () async {
    final screen = fakeScreen();
    await runMaximizedPanelOverlay(
      screen: screen,
      editor: LineEditor(screen: screen),
      title: 'agent',
      chat: screen.chat,
      readEvent: () async => EscapeKey(),
    ).timeout(overlayTimeout);
  });
}
