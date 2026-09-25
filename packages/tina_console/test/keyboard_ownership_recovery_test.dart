import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

import 'line_editor_input_backend_test.dart' show FakeInputBackend;
import 'stdio_fake.dart';

/// Keyboard-ownership recovery tests (tin-DEAD-KEYBOARD seam).
///
/// The editor's keyboard is passed between owners over a session: readLine →
/// cancel monitor (queue mode) → readLine → focused panel → readLine. A
/// mid-session input death looks identical to a lost hand-off: keys arrive
/// but no owner acts on them. These tests pin that every hand-off round-trips:
/// after releasing any owner, a fresh readLine receives typed text again —
/// and [LineEditor.keyCount] keeps ticking 1:1 throughout, so a failure here
/// separates "the stream died upstream" from "an owner kept the keyboard".
Future<void> _flush() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.microtask(() {});
  }
  await Future<void>.delayed(Duration.zero);
}

(LineEditor, FakeInputBackend, Screen) _rig() {
  final io = FakeStdio();
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, 24),
    ansi: AnsiCapable.no,
  );
  final input = FakeInputBackend();
  final editor = LineEditor(
    screen: screen,
    input: input,
    escapeTimeout: Duration.zero,
  );
  return (editor, input, screen);
}

void main() {
  group('monitor → readLine hand-off', () {
    test('after endCancelMonitor a fresh readLine regains the keyboard',
        () async {
      final (ed, input, _) = _rig();
      var cancels = 0;
      final submitted = <String>[];
      ed.beginCancelMonitor(() => cancels++, onQueueSubmit: submitted.add);
      await _flush();

      input.emit(CharInput('q'));
      input.emit(CharInput('1'));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();
      expect(submitted, ['q1'],
          reason: 'queue mode must capture mid-turn text');
      expect(ed.keyCount, 3);

      // Agent finishes → monitor released → prompt re-armed. This is the
      // exact shape of the reported wedge: keys used to work (queued), then
      // the prompt row vanished and typing died.
      ed.endCancelMonitor();
      final line = ed.readLine('> ');
      await _flush();

      input.emit(CharInput('h'));
      input.emit(CharInput('i'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'hi',
          reason: 'post-monitor readLine must own the keyboard again');
      expect(ed.keyCount, 6, reason: 'no event may be lost across hand-off');
      expect(cancels, 0);
      ed.close();
    });

    test('a draft typed during an input-capture window survives into readLine',
        () async {
      final (ed, input, _) = _rig();
      final submitted = <String>[];
      ed.beginInputCaptureWindow(submitted.add);
      await _flush();

      // The user starts retyping while a slow command still runs.
      input.emit(CharInput('r'));
      input.emit(CharInput('e'));
      await _flush();
      expect(submitted, isEmpty);

      // Command unwinds; the window hands the draft to the next readLine.
      ed.endInputCaptureWindow();
      final line = ed.readLine('> ');
      await _flush();
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 're',
          reason: 'tin-y8kh: the capture window must not erase typed text');
      ed.close();
    });

    test('ESC during the monitor cancels once and does not wedge the editor',
        () async {
      final (ed, input, _) = _rig();
      var cancels = 0;
      ed.beginCancelMonitor(() => cancels++);
      await _flush();

      input.emit(EscapeKey());
      await _flush();
      expect(cancels, 1, reason: 'a lone ESC is the monitor-era cancel');
      expect(ed.keyCount, 1);

      // The app then releases the monitor; typing must work normally.
      ed.endCancelMonitor();
      final line = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('o'));
      input.emit(CharInput('k'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'ok',
          reason: 'the post-ESC readLine starts with an empty buffer and '
              'types normally');
      ed.close();
    });
  });

  group('focused panel → readLine hand-off', () {
    test('the armed chat prompt outranks a focused exclusive panel', () async {
      final (ed, input, screen) = _rig();
      final chat =
          PanelFrame(screen: screen, label: 'Chat', conversationId: 'chat');
      final side = PanelFrame(
        screen: screen,
        label: 'Custom',
        conversationId: 'custom',
        inputMode: PanelInputMode.exclusive,
      );
      final received = <InputEvent>[];
      side.onPanelKey = (event) {
        received.add(event);
        return true; // swallow-everything read-only wiring
      };
      chat.setOuter(const Rect(row: 0, col: 0, width: 48, height: 24));
      side.setOuter(const Rect(row: 0, col: 50, width: 48, height: 24));
      final focus = FocusManager()
        ..register(chat)
        ..register(side)
        ..home = chat;
      ed.focusManager = focus;

      // The field wedge (2026-09-24): the prompt is armed AND a read-only
      // panel is still focused from an earlier overlay. Pre-fix, every
      // character was routed to the panel and vanished — the visible `> `
      // with a keyboard that "stopped working". The prompt must win.
      final line = ed.readLine('> ');
      await _flush();
      focus.focusPanel(side);
      await _flush();

      input.emit(CharInput('x'));
      await _flush();
      expect(received, isEmpty,
          reason: 'the panel must not swallow typing while the prompt is '
              'armed');
      expect(ed.editState.buffer, 'x',
          reason: 'typed text lands in the armed prompt');
      expect(ed.keyCount, 1);

      // Scrolling the read-only view while the prompt waits stays useful:
      // wheel events keep their panel route.
      final wheel = ScrollEvent(up: true);
      input.emit(wheel);
      await _flush();
      expect(received, [same(wheel)],
          reason: 'wheel scroll is panel-owned even under an armed prompt');
      expect(ed.editState.buffer, 'x');

      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'x',
          reason: 'the prompt submits normally despite the panel focus');
      expect(ed.keyCount, 3, reason: 'zero events lost');

      // The documented recovery chord still works under the wedge: ctrl+G
      // engages the focus ring even with the prompt armed.
      final line2 = ed.readLine('> ');
      await _flush();
      input.emit(ControlKey(ControlCode.ctrlG));
      await _flush();
      expect(focus.isCycling, isTrue, reason: 'ctrlG reaches the ring');
      input.emit(EscapeKey());
      await _flush();
      expect(focus.isCycling, isFalse);
      input.emit(CharInput('o'));
      input.emit(CharInput('k'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line2, 'ok');
      expect(received.whereType<CharInput>(), isEmpty,
          reason: 'not one typed character ever reached the panel');
      ed.close();
    });

    test('PgUp/PgDn scroll a panel spawned behind the armed prompt', () async {
      // The workflow-launch wedge (tin-SCROLL-PANELS): a run panel (or
      // delegated sub-agent view) spawns mid-turn WITHOUT stealing focus, so
      // the chat prompt row is still armed and visible while the new panel
      // holds focus. Pre-fix, the armed-prompt stand-down at dispatch step 6
      // (and the exclusive-panel route) exempted only the wheel — PgUp/PgDn
      // fell through into the editor's no-op pageUp/pageDown case and the
      // panel transcript never scrolled.
      final (ed, input, screen) = _rig();
      final chat =
          PanelFrame(screen: screen, label: 'Chat', conversationId: 'chat');
      final run = PanelFrame(
        screen: screen,
        label: 'wf run',
        conversationId: 'wf-run-1',
        inputMode: PanelInputMode.readOnly,
      );
      var pages = 0;
      run.onScroll = (deltaPages) => pages += deltaPages;
      chat.setOuter(const Rect(row: 0, col: 0, width: 48, height: 24));
      run.setOuter(const Rect(row: 0, col: 50, width: 48, height: 24));
      final focus = FocusManager()
        ..register(chat)
        ..register(run)
        ..home = chat;
      ed.focusManager = focus;

      // The spawn sequence: the prompt is armed first, THEN the panel takes
      // focus (build panels never steal the draft).
      final line = ed.readLine('> ');
      await _flush();
      focus.focusPanel(run);
      await _flush();

      input.emit(ArrowKey(ArrowDirection.pageUp));
      await _flush();
      expect(pages, -1,
          reason: 'PgUp scrolls the focused panel while the prompt waits');
      input.emit(ArrowKey(ArrowDirection.pageDown));
      await _flush();
      expect(pages, 0, reason: 'PgDn pages back toward the tail');
      expect(ed.editState.buffer, isEmpty,
          reason: 'the page keys never leak into the prompt draft');

      // Plain arrows stay prompt-owned: command-history recall must survive.
      input.emit(ArrowKey(ArrowDirection.up));
      await _flush();
      expect(pages, 0, reason: 'the up arrow is not a panel scroll');

      input.emit(CharInput('o'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'o', reason: 'the prompt still submits normally');
      ed.close();
    });

    test('ctrlG is claimed by the focus ring before the cancel monitor',
        () async {
      final (ed, input, screen) = _rig();
      final chat =
          PanelFrame(screen: screen, label: 'Chat', conversationId: 'chat');
      final focus = FocusManager()
        ..register(chat)
        ..home = chat;
      ed.focusManager = focus;

      var cancels = 0;
      ed.beginCancelMonitor(() => cancels++);
      await _flush();

      input.emit(ControlKey(ControlCode.ctrlG));
      await _flush();
      expect(focus.isCycling, isTrue,
          reason: 'focus-ring keys outrank the monitor (dispatch order)');
      expect(cancels, 0);
      expect(ed.keyCount, 1);

      ed.endCancelMonitor();
      focus.cancel();
      final line = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('z'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'z');
      ed.close();
    });

    test('a panel handler that CLAIMS ctrlG cannot steal it from the ring',
        () async {
      // The entry key is offered to the focus ring before any panel handler,
      // so a handler's claim cannot make the documented escape hatch
      // unreachable: ownership is decided in the dispatch order, not by the
      // handler's return value. (An earlier comment on the wedge test claimed
      // the opposite — that a claiming handler ate ctrlG. It does not; this
      // pins that so the note cannot drift back.)
      final (ed, input, screen) = _rig();
      final chat =
          PanelFrame(screen: screen, label: 'Chat', conversationId: 'chat');
      final side = PanelFrame(
        screen: screen,
        label: 'Environment',
        conversationId: 'env',
        inputMode: PanelInputMode.readOnly,
      );
      final seen = <InputEvent>[];
      side.onPanelKey = (event) {
        seen.add(event);
        return true; // greediest possible handler: claims everything
      };
      final focus = FocusManager()
        ..register(chat)
        ..register(side)
        ..home = chat;
      ed.focusManager = focus;

      // Mid-turn (monitor armed) with the side panel focused.
      ed.beginCancelMonitor(() {});
      await _flush();
      focus.focusPanel(side);
      await _flush();
      input.emit(ControlKey(ControlCode.ctrlG));
      await _flush();
      expect(focus.isCycling, isTrue,
          reason: 'the ring claims ctrlG ahead of the focused panel');
      expect(seen, isEmpty,
          reason: 'a claimed ctrlG must never reach the panel handler');

      input.emit(EscapeKey());
      await _flush();
      expect(focus.isCycling, isFalse);

      // And with the prompt armed (idle) the same rule holds.
      ed.endCancelMonitor();
      final line = ed.readLine('> ');
      await _flush();
      input.emit(ControlKey(ControlCode.ctrlG));
      await _flush();
      expect(focus.isCycling, isTrue,
          reason: 'an armed prompt does not hand ctrlG to the panel either');
      expect(seen, isEmpty,
          reason: 'still nothing for the panel handler to claim');
      input.emit(EscapeKey());
      await _flush();
      input.emit(CharInput('o'));
      input.emit(CharInput('k'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'ok', reason: 'no event lost across the ring trip');
      ed.close();
    });
  });
}
