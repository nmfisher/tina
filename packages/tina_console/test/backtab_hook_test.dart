import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// The editor's `onBackTab` hook (Shift+Tab, CSI Z): offered after the modal
/// layer but before the focus ring — the same rank as `onMaximizeToggle` —
/// and in queue mode alongside it. Consumed only when the hook claims it; a
/// declining or unset hook means the key is dropped (backtab has no editor
/// binding, and it must NEVER land in the buffer). Driven through real byte
/// input, `ESC [ Z` and all.
void main() {
  late FakeStdio io;
  late Screen screen;
  late LineEditor editor;

  setUp(() {
    io = FakeStdio();
    screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    editor = LineEditor(screen: screen);
  });

  Future<void> flush() async {
    await Future<void>.microtask(() {});
    await Future<void>.microtask(() {});
    await Future<void>.delayed(Duration.zero);
  }

  // Shift+Tab over a TTY: ESC [ Z.
  const backtab = [0x1b, 0x5b, 0x5a];

  test('shift+tab fires the hook and is consumed when it returns true',
      () async {
    var fired = 0;
    editor.onBackTab = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([...backtab, 0x0d]); // Shift+Tab, then Enter
    expect(await f, '', reason: 'shift+tab consumed; Enter alone submits');
    expect(fired, 1);
  });

  test('a declining hook drops the key — nothing is typed, buffer intact',
      () async {
    var fired = 0;
    editor.onBackTab = () {
      fired++;
      return false;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x61, ...backtab, 0x0d]); // 'a', Shift+Tab, Enter
    expect(await f, 'a', reason: 'the backtab contributed no characters');
    expect(fired, 1);
  });

  test('an unset hook is harmless — the key is dropped, not typed', () async {
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x61, ...backtab, 0x62, 0x0d]); // 'a', Shift+Tab, 'b', Enter
    expect(await f, 'ab');
  });

  test('plain Tab never fires the hook', () async {
    var fired = 0;
    editor.onBackTab = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x09, 0x0d]); // Tab, Enter
    expect(await f, '');
    expect(fired, 0, reason: '0x09 Tab and CSI Z backtab are distinct keys');
  });

  test('shift+tab fires the hook in queue mode (agent turn running)',
      () async {
    var fired = 0;
    editor.onBackTab = () {
      fired++;
      return true;
    };
    // Queue mode: the cancel monitor is active while an agent turn runs and
    // keys route through _handleQueueEvent, not _dispatchEvent.
    var cancelled = false;
    editor.beginCancelMonitor(() => cancelled = true, onQueueSubmit: (_) {});
    await flush();
    io.feedBytes(backtab);
    await flush();
    expect(fired, 1, reason: 'mode cycling works while the agent runs');
    expect(cancelled, isFalse, reason: 'shift+tab is not a cancel');
    editor.endCancelMonitor();
  });
}
