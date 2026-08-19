import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// Ctrl+C at every input state — the regression matrix. Ctrl+C must behave
/// identically whether or not the maximize toggle hook is installed: the
/// hook consumes only Ctrl+O, and every other key (Ctrl+C included) flows
/// through dispatch unchanged.
void main() {
  Future<void> flush() async {
    await Future<void>.microtask(() {});
    await Future<void>.microtask(() {});
    await Future<void>.delayed(Duration.zero);
  }

  (FakeStdio, Screen, LineEditor) rig() {
    final io = FakeStdio();
    final screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    return (io, screen, LineEditor(screen: screen));
  }

  test('idle prompt: ctrl+c then ctrl+c exits readLine', () async {
    final (io, _, ed) = rig();
    final f = ed.readLine('> ');
    await flush();
    var exited = false;
    f.then((_) => exited = true);
    io.feedBytes([0x03]);
    await flush();
    expect(exited, isFalse,
        reason: 'the first ctrl+c arms the exit confirm, it does not exit');
    io.feedBytes([0x03]);
    expect(await f, isNull);
  });

  test('idle prompt with the maximize hook armed: ctrl+c is untouched',
      () async {
    final (io, _, ed) = rig();
    var maximizeFired = 0;
    ed.onMaximizeToggle = () {
      maximizeFired++;
      return true;
    };
    final f = ed.readLine('> ');
    await flush();
    io.feedBytes([0x03, 0x03]);
    expect(await f, isNull);
    expect(maximizeFired, 0, reason: 'ctrl+c never reaches the hook');
  });

  test('idle prompt with text: ctrl+c clears the buffer, not the prompt',
      () async {
    final (io, _, ed) = rig();
    final f = ed.readLine('> ');
    await flush();
    io.feedBytes([0x61, 0x62, 0x03, 0x0d]); // a, b, ctrl+c, enter
    expect(await f, '');
  });

  test('queue mode (agent running): ctrl+c fires the cancel handler',
      () async {
    final (io, _, ed) = rig();
    var cancelled = 0;
    ed.beginCancelMonitor(() => cancelled++, onQueueSubmit: (_) {});
    await flush();
    io.feedBytes([0x03]);
    await flush();
    expect(cancelled, 1);
  });

  test('queue mode with the maximize hook armed: ctrl+c still cancels',
      () async {
    final (io, _, ed) = rig();
    var maximizeFired = 0;
    ed.onMaximizeToggle = () {
      maximizeFired++;
      return true;
    };
    var cancelled = 0;
    ed.beginCancelMonitor(() => cancelled++, onQueueSubmit: (_) {});
    await flush();
    io.feedBytes([0x03]);
    await flush();
    expect(cancelled, 1);
    expect(maximizeFired, 0);
  });

  test('cancel monitor without queue: ctrl+c cancels', () async {
    final (io, _, ed) = rig();
    var cancelled = 0;
    ed.beginCancelMonitor(() => cancelled++);
    await flush();
    io.feedBytes([0x03]);
    await flush();
    expect(cancelled, 1);
  });

  test('armed global readKey (approval): ctrl+c answers the prompt',
      () async {
    final (io, _, ed) = rig();
    final chat = _Panel(const Rect(row: 0, col: 0, width: 40, height: 20));
    final fm = FocusManager()..register(chat);
    fm.home = chat;
    ed.focusManager = fm;
    ed.readLine('> ');
    await flush();
    final approval = ed.readKey(globalKeys: true);
    io.feedBytes([0x03]);
    final ev = await approval.timeout(const Duration(seconds: 2));
    expect(ev, isA<ControlKey>());
    expect((ev as ControlKey).code, ControlCode.ctrlC);
  });

  test('an open screen-owning readKey (overlay): ctrl+c reaches the overlay',
      () async {
    // The maximize/tool-output shape: the overlay's own readKey loop sees
    // ctrl+c and closes — the editor never interprets it as cancel/exit.
    final (io, _, ed) = rig();
    final overlay = ed.readKey(); // non-global: the overlay shape
    io.feedBytes([0x03]);
    final ev = await overlay.timeout(const Duration(seconds: 2));
    expect((ev as ControlKey).code, ControlCode.ctrlC);
  });
}

class _Panel extends Focusable {
  @override
  final Rect bounds;
  _Panel(this.bounds);
  @override
  bool get hasFocus => false;
  @override
  void focus() {}
  @override
  void blur() {}
  @override
  bool handleEvent(InputEvent e) => false;
}
