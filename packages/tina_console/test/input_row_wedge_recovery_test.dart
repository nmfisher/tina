import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

import 'line_editor_input_backend_test.dart' show FakeInputBackend;
import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Read-only-panel wedge recovery (tin-DEAD-KEYBOARD seam).
///
/// When a read-only, host-only panel takes focus (the environment-agent
/// panel appears mid-session), the coordinator wires every text key to the
/// panel and hides the shared input row. The exact production calls under
/// the wedge:
///
///   - focus:   `screen.input.setBoundsOverride(Rect.empty)`  (coordinator :253)
///              plus `editor.suspendSharedInput()`            (:371/:396)
///   - consume: exclusive [PanelInputMode] + `onPanelKey` swallow all text keys
///   - restore: `screen.input.setBoundsOverride(null)`        (region.dart:1726)
///              and the editor re-arms `readLine`.
///
/// If that restore step is skipped or reordered, the user sees the reported
/// shape: the prompt row is gone and typing does nothing — while the stream
/// itself is fine (ctrl+C still quits). These tests pin that the seam
/// round-trips: after hide → type-into-panel → restore, a fresh readLine
/// owns the keyboard again, the row is painted, and [LineEditor.keyCount]
/// proves no event was dropped on the way.
Future<void> _flush() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.microtask(() {});
  }
  await Future<void>.delayed(Duration.zero);
}

const _inputRow = 21; // 24 rows − status strip − spinner (bottom-3)

String _row(FakeStdio io) {
  final vt = VirtualTerminal(width: 100, height: 24)
    ..feed(io.written.toString());
  return vt.rowText(_inputRow);
}

class _Rig {
  final LineEditor editor;
  final FakeInputBackend input;
  final Screen screen;
  final FakeStdio io;
  final FocusManager focus;
  final PanelFrame chat;
  final PanelFrame readOnly;
  final eaten = <InputEvent>[];

  static Future<_Rig> create() async {
    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24),
      ansi: AnsiCapable.yes,
    );
    final input = FakeInputBackend();
    final editor = LineEditor(
      screen: screen,
      input: input,
      escapeTimeout: Duration.zero,
    );
    // Production always shows a prompt before a panel can steal focus, which
    // seeds the editor's remembered prompt string. Mirror that so repaints
    // after the wedge paint '> ' instead of a blank. The flush between arming
    // and submitting is not cosmetic: readLine's body runs asynchronously, so
    // an Enter emitted synchronously lands before _completer exists — the
    // warmup prompt would stay armed as a zombie, and the prompt stand-down
    // (the dead-keyboard fix) would then rightly keep every panel route off.
    final warmup = editor.readLine('> ');
    await _flush();
    input.emit(ControlKey(ControlCode.enter));
    unawaited(warmup);    final chat = PanelFrame(
        screen: screen, label: 'Chat', conversationId: 'chat');
    final ro = PanelFrame(
      screen: screen,
      label: 'Environment',
      conversationId: 'env',
      inputMode: PanelInputMode.exclusive,
    );
    final rig = _Rig._(io, screen, input, editor, chat, ro);
    ro.onPanelKey = (event) {
      rig.eaten.add(event);
      return true; // read-only content: swallow everything
    };
    chat.setOuter(const Rect(row: 0, col: 0, width: 48, height: 24));
    ro.setOuter(const Rect(row: 0, col: 50, width: 48, height: 24));
    rig.focus
      ..register(chat)
      ..register(ro)
      ..home = chat;
    editor.focusManager = rig.focus;
    return rig;
  }

  _Rig._(this.io, this.screen, this.input, this.editor, this.chat,
      this.readOnly) : focus = FocusManager();
}

void main() {
  group('read-only-panel wedge: hide and restore of the shared input row', () {
    test('setBoundsOverride(empty) hides the row; null + refresh restores it',
        () async {
      final rig = await _Rig.create();
      final ed = rig.editor;
      final io = rig.io;
      final screen = rig.screen;
      final line = ed.readLine('> ');
      await _flush();
      expect(_row(io), contains('> '));
      expect(screen.input.bounds.isEmpty, isFalse);

      // The wedge lands: coordinator hides the shared row.
      screen.input.setBoundsOverride(Rect.empty);
      ed.suspendSharedInput();
      await _flush();
      expect(screen.input.bounds.isEmpty, isTrue,
          reason: 'the override is what hides the prompt row');

      // Recovery: coordinator points the row back at the layout.
      screen.input.setBoundsOverride(null);
      ed.refresh();
      await _flush();
      expect(screen.input.bounds.isEmpty, isFalse);
      expect(_row(io), contains('> '),
          reason: 'the prompt row must be repainted after the override '
              'clears — a blank row reads as a dead keyboard');
      ed.close();
      unawaited(line);
    });

    test('full wedge timeline: panel eats keys, restore hands them back',
        () async {
      final rig = await _Rig.create();
      final ed = rig.editor;
      final input = rig.input;
      final io = rig.io;
      final screen = rig.screen;
      // The wedge era is the monitor era (agent running): exclusive panel
      // routing is only enabled while NO readLine is armed
      // (line_editor.dart:642 — `_keyCompleter != null` returns early).
      var cancels = 0;
      ed.beginCancelMonitor(() => cancels++);
      await _flush();
      rig.focus.focusPanel(rig.readOnly);
      screen.input.setBoundsOverride(Rect.empty);
      ed.suspendSharedInput();
      await _flush();

      // The user types into the void: the panel swallows everything.
      input.emit(CharInput('x'));
      input.emit(CharInput('y'));
      await _flush();
      expect(rig.eaten.map((e) => e is CharInput ? e.text : ''), ['x', 'y'],
          reason: 'the read-only panel consumes text keys while focused');
      expect(ed.editState.buffer, isEmpty,
          reason: 'nothing may leak into the editor while suspended');
      expect(ed.keyCount, 3,
          reason: 'the stream never stops ticking (the warmup Enter counts '
              'now that it is delivered for real instead of racing the '
              'readLine pump)');

      // Recovery: un-hide the row, refocus the chat panel, release the
      // monitor (the app always does this before re-arming the prompt —
      // see the sharp-edge note in the README below), then re-arm readLine.
      expect(cancels, 0,
          reason: 'typed text under the wedge must not fire the cancel');
      screen.input.setBoundsOverride(null);
      ed.refresh();
      rig.focus.focusPanel(rig.chat);
      ed.endCancelMonitor();
      final line = ed.readLine('> ');
      await _flush();
      expect(_row(io), contains('> '));

      input.emit(CharInput('h'));
      input.emit(CharInput('i'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'hi',
          reason: 'after the restore choreography the editor must own the '
              'keyboard again — this is the wedge recovery invariant');
      expect(ed.keyCount, 6, reason: 'zero events lost across the wedge');
      ed.close();
    });

    test('ctrlG still reaches the focus ring under the wedge (documented out)',
        () async {
      final rig = await _Rig.create();
      final ed = rig.editor;
      final input = rig.input;
      final screen = rig.screen;
      // Monitor era: exclusive routing is live only without an armed readLine.
      ed.beginCancelMonitor(() {});
      await _flush();
      rig.focus.focusPanel(rig.readOnly);
      // The panel swallows text keys but DECLINES the ring entry key — the
      // correct wiring for a read-only panel, so ctrlG stays usable.
      rig.readOnly.onPanelKey = (event) {
        if (event is ControlKey && event.code == ControlCode.ctrlG) {
          return false;
        }
        rig.eaten.add(event);
        return true;
      };
      screen.input.setBoundsOverride(Rect.empty);
      ed.suspendSharedInput();
      await _flush();

      input.emit(ControlKey(ControlCode.ctrlG));
      await _flush();
      // NOTE: the ring is offered its entry keys before any focused panel's
      // handler runs, so ctrlG is reachable under the wedge no matter what the
      // handler does — declining it (as our read-only wiring does), or even
      // claiming it. An earlier note here claimed the opposite ("the panel
      // route eats a claimed ctrlG"); that was wrong, and
      // keyboard_ownership_recovery_test pins the real rule: a handler that
      // claims everything still never sees ctrlG. What this test pins is the
      // other half — a DECLINING handler must not be needed for the ring to
      // engage.
      expect(rig.focus.isCycling, isTrue,
          reason: 'with a declining panel handler, ctrlG must still reach '
              'the focus ring');
      expect(rig.eaten, isEmpty,
          reason: 'a declined key is not delivered to the panel stream');

      // Escape leaves cycling; chat refocus completes the documented out.
      input.emit(EscapeKey());
      await _flush();
      expect(rig.focus.isCycling, isFalse);
      rig.focus.focusPanel(rig.chat);
      ed.endCancelMonitor();
      ed.close();
    });

    test('queue monitor under the wedge: queued text stays queued and '
        'readLine regains the keyboard', () async {
      final rig = await _Rig.create();
      final ed = rig.editor;
      final input = rig.input;
      final io = rig.io;
      final screen = rig.screen;
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      await _flush();
      rig.focus.focusPanel(rig.readOnly);
      screen.input.setBoundsOverride(Rect.empty);
      ed.suspendSharedInput();
      await _flush();

      input.emit(CharInput('q'));
      await _flush();
      expect(submitted, isEmpty, reason: 'the panel owns keys under the wedge');

      // Recovery: un-hide the row, hand focus back, release the monitor,
      // then re-arm the prompt.
      screen.input.setBoundsOverride(null);
      rig.focus.focusPanel(rig.chat);
      ed.refresh();
      ed.endCancelMonitor();
      final line = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('o'));
      input.emit(CharInput('k'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'ok');
      expect(_row(io), contains('> '));
      ed.close();
    });
  });
}
