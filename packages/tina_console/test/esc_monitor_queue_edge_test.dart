import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

import 'line_editor_input_backend_test.dart' show FakeInputBackend;
import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// ESC-only cancel-monitor sharp edges (queue mode row sharing).
///
/// The agent-turn monitor and the queue draft share ONE screen row: the same
/// `screen.input` region that readLine paints its prompt on. Whoever handles
/// a key must leave that row in a truthful state — a stale draft on screen
/// reads to the user exactly like "my keyboard stopped working" (text
/// appears on screen but the prompt is gone), which is the shape reported in
/// the dead-keyboard tickets.
///
/// Regression window note: `f29030c` (queue-mode arrows) taught
/// `_handleQueueEvent`/`_renderQueueDisplay` to render into the shared row
/// without checking `_queueModeActive`. These tests pin the row choreography
/// so a future change cannot silently drop it again.
Future<void> _flush() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.microtask(() {});
  }
  await Future<void>.delayed(Duration.zero);
}

(LineEditor, FakeInputBackend, Screen, FakeStdio, Future<String?>) _rig() {
  final io = FakeStdio();
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(100, 24),
    ansi: AnsiCapable.no,
  );
  final input = FakeInputBackend();
  final editor = LineEditor(
    screen: screen,
    input: input,
    escapeTimeout: Duration.zero,
  );
  // Production always shows a prompt before an agent turn starts, which is
  // what seeds the editor's remembered prompt string. Mirror that: arm a
  // readLine and complete it, so monitor-mode renders paint '> ' like the
  // real app instead of a blank.
  final warmup = editor.readLine('> ');
  input.emit(ControlKey(ControlCode.enter));
  return (editor, input, screen, io, warmup);
}

/// The shared input row: bottom minus 3 (status strip + spinner rows below).
const _inputRow = 21;

String _row(FakeStdio io) {
  final vt = VirtualTerminal(width: 100, height: 24)
    ..feed(io.written.toString());
  return vt.rowText(_inputRow);
}

void main() {
  group('ESC-only monitor (no queue submission)', () {
    test('ESC cancels exactly once and cannot double-fire on the next ESC',
        () async {
      final (ed, input, _, _, _) = _rig();
      var cancels = 0;
      // The app-shaped handler: cancel releases the monitor synchronously.
      ed.beginCancelMonitor(() {
        cancels++;
        ed.endCancelMonitor();
      });
      await _flush();

      input.emit(EscapeKey());
      await _flush();
      expect(cancels, 1, reason: 'a lone ESC is the monitor-era cancel');
      expect(ed.keyCount, 1);

      // A second ESC lands after the monitor is gone: the double-ESC window
      // is open (ESC #1 just happened) but there is no active readLine to
      // force-cancel — it must be inert, not throw, not re-enter the handler.
      input.emit(EscapeKey());
      await _flush();
      expect(cancels, 1, reason: 'the handler was released; ESC is unowned');
      expect(ed.keyCount, 2, reason: 'the stream stays alive throughout');

      // And a prompt armed afterwards owns the keyboard normally.
      final line = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('h'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'h');
      ed.close();
    });
  });

  group('queue-mode draft and the shared input row', () {
    test('ESC clears the queued draft first; only an empty buffer cancels',
        () async {
      final (ed, input, _, io, _) = _rig();
      var cancels = 0;
      final submitted = <String>[];
      ed.beginCancelMonitor(() => cancels++, onQueueSubmit: submitted.add);
      await _flush();

      input.emit(CharInput('a'));
      input.emit(CharInput('b'));
      input.emit(CharInput('c'));
      await _flush();

      // Sharp edge under test: clearing the draft must repaint the row.
      input.emit(EscapeKey());
      await _flush();
      expect(cancels, 0,
          reason: 'ESC with a non-empty draft clears, never cancels');
      expect(_row(io), contains('> '),
          reason: 'the row must show the prompt again after the clear — '
              'a stale "abc" on screen mimics a dead keyboard');
      expect(ed.keyCount, 4);

      // Now the buffer is empty: ESC cancels.
      input.emit(EscapeKey());
      await _flush();
      expect(cancels, 1);
      ed.endCancelMonitor();
      ed.close();
    });

    test('the row shows the queue count while queued text waits', () async {
      final (ed, input, _, io, _) = _rig();
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      await _flush();

      input.emit(CharInput('o'));
      input.emit(CharInput('n'));
      input.emit(CharInput('e'));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();
      expect(submitted, ['one']);

      // one is submitted (qCount 1), the draft is empty → the row advertises
      // the queue instead of silently going blank.
      expect(_row(io), contains('[1 queued]'),
          reason: 'submitted-but-not-started text must stay visible');

      input.emit(CharInput('t'));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();
      expect(submitted, ['one', 't']);
      expect(_row(io), contains('[2 queued]'));
      ed.endCancelMonitor();
      ed.close();
    });

    test('endCancelMonitor leaves the prompt row painted (queue mode)', () async {
      final (ed, input, _, io, _) = _rig();
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      await _flush();

      input.emit(CharInput('d'));
      await _flush();
      ed.endCancelMonitor();
      await _flush();

      expect(_row(io), contains('> '),
          reason: 'releasing the monitor is the last writer before readLine '
              're-arms; dropping the row here is the reported blank-prompt '
              'wedge');
      final line = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('h'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'h');
      ed.close();
    });

    test('vertical arrows are inert in queue mode and lose nothing',
        () async {
      final (ed, input, _, io, _) = _rig();
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      await _flush();

      input.emit(CharInput('a'));
      input.emit(CharInput('b'));
      input.emit(ArrowKey(ArrowDirection.up));
      input.emit(ArrowKey(ArrowDirection.left));
      input.emit(CharInput('c'));
      await _flush();

      input.emit(ControlKey(ControlCode.enter));
      expect(submitted, ['acb'],
          reason: 'left arrow edits, up arrow is inert — either way the '
              'draft must not be dropped');
      ed.endCancelMonitor();
      ed.close();
    });
  });
}
