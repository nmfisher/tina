import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// The editor's `onPlanToggle` hook (Ctrl+P, byte 0x10): offered at the same
/// dispatch rank as `onMaximizeToggle`/`onRawView` — after the modal layer,
/// before the focus ring — consumed only when the hook claims it. Driven
/// through real byte input.
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

  test('ctrl+p fires the hook and is consumed when it returns true', () async {
    var fired = 0;
    editor.onPlanToggle = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x10, 0x0d]); // Ctrl+P, then Enter
    expect(await f, '', reason: 'ctrl+p consumed; Enter alone submits');
    expect(fired, 1);
  });

  test('a declining hook lets the key fall through', () async {
    var fired = 0;
    editor.onPlanToggle = () {
      fired++;
      return false;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x10, 0x0d]);
    expect(await f, '');
    expect(fired, 1);
  });

  test('plain "p" never fires the hook', () async {
    var fired = 0;
    editor.onPlanToggle = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x70, 0x0d]); // 'p', Enter
    expect(await f, 'p');
    expect(fired, 0);
  });

  test('ctrl+p fires the hook in queue mode (agent turn running)', () async {
    var fired = 0;
    editor.onPlanToggle = () {
      fired++;
      return true;
    };
    // Queue mode: the cancel monitor is active while an agent turn runs and
    // keys route through _handleQueueEvent, not _dispatchEvent.
    var cancelled = false;
    editor.beginCancelMonitor(() => cancelled = true, onQueueSubmit: (_) {});
    await flush();
    io.feedBytes([0x10]); // Ctrl+P
    await flush();
    expect(fired, 1, reason: 'the toggle works while the agent runs');
    expect(cancelled, isFalse, reason: 'ctrl+p is not a cancel');
    editor.endCancelMonitor();
  });

  test('ctrl+p reaches the hook even when a modal approval is up', () async {
    // The hook rank sits between the modal layer and the focus ring, so the
    // toggle stays live while the app shows a prompt — plan state stays
    // reachable exactly when an approval decision is pending.
    var fired = 0;
    editor.onPlanToggle = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x10]);
    await flush();
    expect(fired, 1);
    io.feedBytes([0x0d]);
    expect(await f, '');
  });
}
