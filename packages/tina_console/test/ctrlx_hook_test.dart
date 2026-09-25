import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// The editor's `onClosePanel` hook (Ctrl+X, 0x18): offered at the app-hook
/// rank in normal dispatch, through the armed-readKey seam (window management
/// must work while a prompt/approval owns the keyboard), and in queue mode
/// alongside the other app hooks. Consumed only when the hook claims it; a
/// declining or unset hook drops the key — Ctrl+X must NEVER land in the
/// buffer. Driven through real byte input.
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

  const ctrlX = [0x18];

  test('ctrl+x fires the hook and is consumed when it returns true',
      () async {
    var fired = 0;
    editor.onClosePanel = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([...ctrlX, 0x0d]); // Ctrl+X, then Enter
    expect(await f, '', reason: 'ctrl+x consumed; Enter alone submits');
    expect(fired, 1);
  });

  test('a declining hook drops the key — nothing is typed, buffer intact',
      () async {
    var fired = 0;
    editor.onClosePanel = () {
      fired++;
      return false;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x61, ...ctrlX, 0x0d]); // 'a', Ctrl+X, Enter
    expect(await f, 'a', reason: 'the declined ctrl+x contributed nothing');
    expect(fired, 1);
  });

  test('an unset hook is harmless — the key is dropped, not typed', () async {
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x61, ...ctrlX, 0x62, 0x0d]); // 'a', Ctrl+X, 'b', Enter
    expect(await f, 'ab');
  });

  test('plain chars are never hijacked: only 0x18 fires the hook', () async {
    var fired = 0;
    editor.onClosePanel = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x78, 0x0d]); // 'x' (the run panels' close key), Enter
    expect(await f, 'x', reason: 'printable x types; only the chord closes');
    expect(fired, 0);
  });

  test('ctrl+x fires the hook in queue mode (agent turn running)', () async {
    var fired = 0;
    editor.onClosePanel = () {
      fired++;
      return true;
    };
    // Queue mode: the cancel monitor is active while an agent turn runs and
    // keys route through the queue handler, not normal dispatch.
    var cancelled = false;
    editor.beginCancelMonitor(() => cancelled = true, onQueueSubmit: (_) {});
    await flush();
    io.feedBytes(ctrlX);
    await flush();
    expect(fired, 1, reason: 'closing a finished panel works mid-turn');
    expect(cancelled, isFalse, reason: 'ctrl+x is not a cancel');
    editor.endCancelMonitor();
  });
}
