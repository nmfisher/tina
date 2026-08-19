import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// The editor's `onMaximizeToggle` hook (Ctrl+O, byte 0x0F): offered after
/// the modal layer but before the focus ring, consumed only when the hook
/// claims it. Driven through real byte input.
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

  test('ctrl+o fires the hook and is consumed when it returns true',
      () async {
    var fired = 0;
    editor.onMaximizeToggle = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x0f, 0x0d]); // Ctrl+O, then Enter
    expect(await f, '', reason: 'ctrl+o consumed; Enter alone submits');
    expect(fired, 1);
  });

  test('a declining hook lets the key fall through', () async {
    var fired = 0;
    editor.onMaximizeToggle = () {
      fired++;
      return false;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x0f, 0x0d]);
    expect(await f, '');
    expect(fired, 1);
  });

  test('plain "o" never fires the hook', () async {
    var fired = 0;
    editor.onMaximizeToggle = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x6f, 0x0d]); // 'o', Enter
    expect(await f, 'o');
    expect(fired, 0);
  });

  test('ctrl+o fires the hook in queue mode (agent turn running)', () async {
    var fired = 0;
    editor.onMaximizeToggle = () {
      fired++;
      return true;
    };
    // Queue mode: the cancel monitor is active while an agent turn runs and
    // keys route through _handleQueueEvent, not _dispatchEvent.
    var cancelled = false;
    editor.beginCancelMonitor(() => cancelled = true, onQueueSubmit: (_) {});
    await flush();
    io.feedBytes([0x0f]); // Ctrl+O
    await flush();
    expect(fired, 1, reason: 'the toggle works while the agent runs');
    expect(cancelled, isFalse, reason: 'ctrl+o is not a cancel');
    editor.endCancelMonitor();
  });
}
