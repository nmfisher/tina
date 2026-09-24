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
      expect(submitted, ['q1'], reason: 'queue mode must capture mid-turn text');
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
    test('panel ownership steals keys, ctrlG cycle + refocus restores typing',
        () async {
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
        return false;
      };
      chat.setOuter(const Rect(row: 0, col: 0, width: 48, height: 24));
      side.setOuter(const Rect(row: 0, col: 50, width: 48, height: 24));
      final focus = FocusManager()
        ..register(chat)
        ..register(side)
        ..home = chat;
      ed.focusManager = focus;

      // The wedge shape from the field: a panel (e.g. the environment agent)
      // appears mid-session and takes exclusive focus while the prompt sits
      // armed underneath.
      final line = ed.readLine('> ');
      await _flush();
      focus.focusPanel(side);
      await _flush();

      input.emit(CharInput('x'));
      await _flush();
      expect(received.map((e) => e is CharInput ? e.text : ''), ['x'],
          reason: 'the exclusive panel owns the keyboard while focused');
      expect(ed.editState.buffer, isEmpty,
          reason: 'stolen keys must not leak into the editor buffer');
      expect(ed.keyCount, 1, reason: 'the stream itself is still alive');

      // Recovery, as the app does it: engage the ring (ctrlG), leave cycling
      // (Esc), and hand focus back to the chat panel.
      input.emit(ControlKey(ControlCode.ctrlG));
      await _flush();
      expect(focus.isCycling, isTrue, reason: 'ctrlG engages the focus ring');
      input.emit(EscapeKey());
      await _flush();
      expect(focus.isCycling, isFalse, reason: 'Esc left the ring');
      focus.focusPanel(chat);
      await _flush();

      input.emit(CharInput('h'));
      input.emit(CharInput('i'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'hi',
          reason: 'after refocusing the chat panel the editor types again');
      expect(ed.keyCount, 6, reason: 'ownership changes, the stream never drops');
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
  });
}
