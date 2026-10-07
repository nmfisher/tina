import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// Clearing a draft must not cancel work, submit text or answer an approval.
void main() {
  Future<void> flush() => pumpEventQueue();

  (FakeStdio, LineEditor) rig() {
    final io = FakeStdio();
    final screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    final editor = LineEditor(screen: screen);
    addTearDown(io.close);
    addTearDown(screen.dispose);
    addTearDown(editor.close);
    return (io, editor);
  }

  test('empty input exits on one Ctrl+C and cannot be reopened', () async {
    final (io, editor) = rig();
    final line = editor.readLine('> ');
    await flush();
    io.feedBytes([3, 120, 13]);
    expect(await line, isNull);
    await editor.whenQuit;
    expect(editor.quitRequested, isTrue);
    expect(editor.draftText, isEmpty);
    expect(await editor.readLine('> '), isNull);
    expect(await editor.readKey(), ControlKey(ControlCode.ctrlC));
    expect(io.written.toString(), isNot(contains('Ctrl+C again to exit')));
  });

  for (final text in [
    'draft',
    '   ',
    '!echo hello',
    'line1\nline2',
    'x' * 129
  ]) {
    test('nonempty input clears without quitting (${text.length} chars)',
        () async {
      final (io, editor) = rig();
      final line = editor.readLine('> ');
      await flush();
      editor.inject(PasteInput(text));
      editor.inject(ControlKey(ControlCode.ctrlC));
      await flush();
      expect(editor.editState, (buffer: '', cursor: 0));
      expect(editor.quitRequested, isFalse);
      expect(io.written.toString(), isNot(contains('Ctrl+C again to exit')));
      editor.inject(CharInput('replacement'));
      editor.inject(ControlKey(ControlCode.enter));
      expect(await line, 'replacement');
    });
  }

  test('two presses with text clear, then quit', () async {
    final (io, editor) = rig();
    final line = editor.readLine('> ');
    await flush();
    io.feedBytes('draft\x03\x03'.codeUnits);
    expect(await line, isNull);
    expect(editor.quitRequested, isTrue);
  });

  for (final busy in [false, true]) {
    test('approval with draft (busy=$busy): clear, then quit', () async {
      final (_, editor) = rig();
      final line = editor.readLine('> ');
      await flush();
      var cancelled = false;
      final submitted = <String>[];
      if (busy) {
        editor.beginCancelMonitor(() => cancelled = true,
            onQueueSubmit: submitted.add);
      }
      editor.inject(PasteInput('draft\nwith multiple lines'));
      var answered = false;
      final approval = editor.readKey(globalKeys: true);
      approval.then((_) => answered = true);
      editor.inject(ControlKey(ControlCode.ctrlC));
      await flush();
      expect(editor.quitRequested, isFalse);
      expect(editor.draftText, isEmpty);
      expect(answered, isFalse);
      expect(cancelled, isFalse);
      expect(submitted, isEmpty);
      editor.inject(ControlKey(ControlCode.ctrlC));
      expect(await approval, ControlKey(ControlCode.ctrlC));
      expect(await line, isNull);
      expect(editor.quitRequested, isTrue);
      expect(cancelled, isFalse);
    });
  }

  test('busy draft clears without losing submitted messages', () async {
    final (_, editor) = rig();
    var cancelled = false;
    final submitted = <String>[];
    editor.beginCancelMonitor(() => cancelled = true,
        onQueueSubmit: submitted.add);
    editor.inject(CharInput('already queued'));
    editor.inject(ControlKey(ControlCode.enter));
    editor.inject(CharInput('discard this'));
    editor.inject(ControlKey(ControlCode.ctrlC));
    expect(editor.quitRequested, isFalse);
    expect(editor.draftText, isEmpty);
    expect(editor.currentState()['queued_lines'], 1);
    editor.inject(CharInput('replacement'));
    editor.inject(ControlKey(ControlCode.enter));
    expect(submitted, ['already queued', 'replacement']);
    expect(cancelled, isFalse);
  });

  for (final queued in [false, true]) {
    test('empty input during a turn requests exit (queued=$queued)', () async {
      final (_, editor) = rig();
      var cancelled = false;
      editor.onMaximizeToggle = () => fail('Ctrl+C reached maximize');
      editor.beginCancelMonitor(() => cancelled = true,
          onQueueSubmit: queued ? (_) => fail('submitted empty input') : null);
      editor.inject(ControlKey(ControlCode.ctrlC));
      await editor.whenQuit;
      expect(editor.quitRequested, isTrue);
      expect(cancelled, isFalse,
          reason: 'the controller owns cancellation during shutdown');
    });
  }

  for (final global in [false, true]) {
    test('quit releases active and serialized readKey (global=$global)',
        () async {
      final (_, editor) = rig();
      final first = editor.readKey(globalKeys: global);
      final next = editor.readKey(globalKeys: global);
      await flush();
      editor.inject(ControlKey(ControlCode.ctrlC));
      expect(await first, ControlKey(ControlCode.ctrlC));
      expect(await next, ControlKey(ControlCode.ctrlC));
      expect(editor.quitRequested, isTrue);
    });
  }

  test('quit closes an owned dialog and releases its pending reads', () async {
    final (_, editor) = rig();
    final session = editor.openInputSession();
    final reads = [session.read(), session.read()];
    editor.inject(ControlKey(ControlCode.ctrlC));
    expect(
        await Future.wait(reads), everyElement(ControlKey(ControlCode.ctrlC)));
    expect(session.isClosed, isTrue);
    expect(editor.quitRequested, isTrue);
  });
}
