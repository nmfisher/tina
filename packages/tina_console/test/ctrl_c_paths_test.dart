import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// Ctrl+C at every input state — the regression matrix.
///
/// Ctrl+C clears a nonempty shared draft first. With an empty draft, it arms
/// the quit confirmation, then quits on the next press (readLine completes
/// with null; an armed readKey completes with ctrlC). Clearing a draft must
/// not cancel work or answer an approval.
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

  test('idle prompt: ctrl+c arms, second ctrl+c exits readLine', () async {
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

  test('idle prompt: any other key dismisses the armed confirm', () async {
    final (io, _, ed) = rig();
    final f = ed.readLine('> ');
    await flush();
    io.feedBytes([0x03]);
    await flush();
    io.feedBytes([0x78]); // 'x' dismisses the dialog, types into the buffer
    await flush();
    io.feedBytes([0x03, 0x03, 0x03]); // clear + arm + quit
    expect(await f, isNull);
  });

  test('prompt with text: ctrl+c clears, then arms, then quits', () async {
    final (io, _, ed) = rig();
    final f = ed.readLine('> ');
    var exited = false;
    f.then((_) => exited = true);
    await flush();
    io.feedBytes([0x61, 0x62]); // 'ab'
    await flush();
    io.feedBytes([0x03]);
    await flush();
    expect(ed.editState, (buffer: '', cursor: 0));
    expect(ed.currentState()['confirm_visible'], isFalse);
    expect(exited, isFalse);
    expect(io.written.toString(), isNot(contains('Ctrl+C again to exit')));
    io.feedBytes([0x03]);
    await flush();
    expect(ed.currentState()['confirm_visible'], isTrue);
    expect(exited, isFalse);
    io.feedBytes([0x03]);
    expect(await f, isNull);
  });

  test('maximize hook armed: ctrl+c is untouched by the hook', () async {
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

  for (final busy in [false, true]) {
    test('draft with approval (busy=$busy): clear, confirm, quit', () async {
      final (io, _, ed) = rig();
      addTearDown(ed.close);
      addTearDown(io.close);
      final line = ed.readLine('> ');
      await flush();
      var cancelled = false;
      final submitted = <String>[];
      if (busy) {
        ed.beginCancelMonitor(() => cancelled = true,
            onQueueSubmit: submitted.add);
      }
      ed.inject(PasteInput('draft\nwith multiple lines'));
      await flush();
      var answered = false;
      final approval = ed.readKey(globalKeys: true);
      approval.then((_) => answered = true);
      ed.inject(ControlKey(ControlCode.ctrlC));
      await flush();
      expect(ed.currentState()['confirm_visible'], isFalse);
      expect(answered, isFalse);
      expect(cancelled, isFalse);
      expect(submitted, isEmpty);

      ed.inject(ControlKey(ControlCode.ctrlC));
      await flush();
      expect(ed.currentState()['confirm_visible'], isTrue);
      expect(answered, isFalse);
      ed.inject(ControlKey(ControlCode.ctrlC));
      expect(await approval, ControlKey(ControlCode.ctrlC));
      expect(await line, isNull);
      expect(cancelled, isFalse);
    });
  }

  test('busy draft clears without losing submitted messages', () async {
    final (io, _, ed) = rig();
    addTearDown(ed.close);
    addTearDown(io.close);
    var cancelled = false;
    final submitted = <String>[];
    ed.beginCancelMonitor(() => cancelled = true, onQueueSubmit: submitted.add);
    ed.inject(CharInput('already queued'));
    ed.inject(ControlKey(ControlCode.enter));
    ed.inject(CharInput('discard this'));
    ed.inject(ControlKey(ControlCode.ctrlC));
    await flush();
    expect(ed.currentState()['confirm_visible'], isFalse);
    expect(ed.currentState()['queued_lines'], 1);
    ed.inject(CharInput('replacement'));
    ed.inject(ControlKey(ControlCode.enter));
    await flush();
    expect(submitted, ['already queued', 'replacement']);
    expect(cancelled, isFalse);
  });

  test('queue mode (agent running): first ctrl+c arms, second quits', () async {
    final (io, _, ed) = rig();
    var cancelled = 0;
    final submitted = <String>[];
    ed.beginCancelMonitor(() => cancelled++, onQueueSubmit: submitted.add);
    await flush();
    io.feedBytes([0x03]);
    await flush();
    expect(cancelled, 0, reason: 'cancel is Esc-only; ctrl+c arms the quit');
    io.feedBytes([0x03]);
    await flush();
    expect(cancelled, 0);
    expect(submitted, isEmpty);
  });

  test('queue mode with the maximize hook armed: ctrl+c still arms the quit',
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
    io.feedBytes([0x03, 0x03]);
    await flush();
    expect(cancelled, 0);
    expect(maximizeFired, 0);
  });

  test('cancel monitor without queue: ctrl+c does NOT cancel; esc does',
      () async {
    final (io, _, ed) = rig();
    var cancelled = 0;
    ed.beginCancelMonitor(() => cancelled++);
    await flush();
    io.feedBytes([0x03]);
    await flush();
    expect(cancelled, 0, reason: 'the first ctrl+c arms the quit confirm');
    io.feedBytes([0x1b]); // ESC keeps the cancel job
    // A lone ESC byte is only promoted to EscapeKey after the input parser's
    // escape timeout (150ms) — until then it is still a pending sequence, so
    // the editor has seen nothing yet.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await flush();
    expect(cancelled, 1);
  });

  test('armed global readKey (approval): first ctrl+c arms, does NOT answer',
      () async {
    final (io, _, ed) = rig();
    final chat = _Panel(const Rect(row: 0, col: 0, width: 40, height: 20));
    final fm = FocusManager()..register(chat);
    fm.home = chat;
    ed.readLine('> ');
    await flush();
    final approval = ed.readKey(globalKeys: true);
    io.feedBytes([0x03]);
    await flush();
    var answered = false;
    approval.then((_) => answered = true);
    await flush();
    expect(answered, isFalse,
        reason: 'the first ctrl+c arms the quit confirm, it does not answer');
    io.feedBytes([0x1b]); // dismiss the dialog without quitting
    // A lone ESC byte is only promoted to EscapeKey after the parser's escape
    // timeout (150ms); feeding 'y' inside that window would glue to it as
    // Alt+y instead of answering the prompt.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await flush();
    io.feedBytes([0x79]); // 'y' answers normally
    final ev = await approval.timeout(const Duration(seconds: 2));
    expect(ev, isA<CharInput>());
  });

  test('confirmed quit completes an armed readKey with ctrlC (no hang)',
      () async {
    final (io, _, ed) = rig();
    final chat = _Panel(const Rect(row: 0, col: 0, width: 40, height: 20));
    final fm = FocusManager()..register(chat);
    fm.home = chat;
    ed.readLine('> ');
    await flush();
    final approval = ed.readKey(globalKeys: true);
    io.feedBytes([0x03, 0x03]); // arm, then confirm quit
    final ev = await approval.timeout(const Duration(seconds: 2));
    expect(ev, isA<ControlKey>());
    expect((ev as ControlKey).code, ControlCode.ctrlC);
  });

  test('screen-owning readKey (overlay): quit flow spans it identically',
      () async {
    final (io, _, ed) = rig();
    final overlay = ed.readKey(); // non-global: the overlay shape
    await flush();
    io.feedBytes([0x03]);
    await flush();
    var answered = false;
    overlay.then((_) => answered = true);
    await flush();
    expect(answered, isFalse, reason: 'first press only arms the confirm');
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
