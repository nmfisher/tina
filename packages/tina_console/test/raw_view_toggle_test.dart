import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// The editor's `onRawView` hook (Ctrl+R, byte 0x12): offered at the same
/// dispatch rank as `onMaximizeToggle` — after the modal layer, before the
/// focus ring — consumed only when the hook claims it. Driven through real
/// byte input.
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

  test('ctrl+r fires the hook and is consumed when it returns true', () async {
    var fired = 0;
    editor.onRawView = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12, 0x0d]); // Ctrl+R, then Enter
    expect(await f, '', reason: 'ctrl+r consumed; Enter alone submits');
    expect(fired, 1);
  });

  test('a declining hook lets the key fall through', () async {
    var fired = 0;
    editor.onRawView = () {
      fired++;
      return false;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x12, 0x0d]);
    expect(await f, '');
    expect(fired, 1);
  });

  test('plain "r" never fires the hook', () async {
    var fired = 0;
    editor.onRawView = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x72, 0x0d]); // 'r', Enter
    expect(await f, 'r');
    expect(fired, 0);
  });

  test('ctrl+r fires the hook in queue mode (agent turn running)', () async {
    var fired = 0;
    editor.onRawView = () {
      fired++;
      return true;
    };
    // Queue mode: the cancel monitor is active while an agent turn runs and
    // keys route through _handleQueueEvent, not _dispatchEvent.
    var cancelled = false;
    editor.beginCancelMonitor(() => cancelled = true, onQueueSubmit: (_) {});
    await flush();
    io.feedBytes([0x12]); // Ctrl+R
    await flush();
    expect(fired, 1, reason: 'the raw view opens while the agent runs');
    expect(cancelled, isFalse, reason: 'ctrl+r is not a cancel');
    editor.endCancelMonitor();
  });
}
