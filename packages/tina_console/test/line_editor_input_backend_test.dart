import 'dart:async';

import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Test double for [InputBackend]. Lets tests push synthetic [InputEvent]s
/// into the editor without going through stdin parsing — exercises the
/// event-based code paths that bin/tina.dart uses with the notcurses
/// input backend.
class FakeInputBackend implements InputBackend {
  @override
  Future<void> get ready => Future<void>.value();

  final _controller = StreamController<InputEvent>.broadcast(sync: true);
  bool disposed = false;
  final List<InputEvent> injected = [];

  /// Push an event onto the stream as if it came from the terminal.
  void emit(InputEvent event) => _controller.add(event);

  @override
  Stream<InputEvent> get events => _controller.stream;

  @override
  void inject(InputEvent event) {
    if (disposed) return;
    injected.add(event);
    _controller.add(event);
  }

  @override
  void dispose() {
    disposed = true;
    _controller.close();
  }
}

Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

LineEditor _makeEditor(FakeInputBackend input, {FakeStdio? io}) {
  final stdio = io ?? FakeStdio();
  final screen = Screen(
    io: stdio,
    layout: ScreenLayout.fromSize(80, 24),
    ansi: AnsiCapable.no,
  );
  return LineEditor(screen: screen, input: input);
}

void main() {
  group('LineEditor with external InputBackend', () {
    test('readLine consumes events from the injected backend', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      final f = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('h'));
      input.emit(CharInput('i'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await f, 'hi');
      ed.close();
    });

    test('close() does NOT dispose an externally-provided backend', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      ed.close();
      expect(input.disposed, isFalse,
          reason: 'editor must not own a backend it did not create');
    });

    test('default backend IS disposed by close()', () async {
      // No external input → editor builds its own AnsiInputBackend.
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
        ansi: AnsiCapable.no,
      );
      final ed = LineEditor(screen: screen);
      ed.readLine('> ');
      await _flush();
      ed.close();
      // After close, feeding bytes into the same stdin should produce no
      // observable side effect (sub cancelled).
      io.feedBytes([0x41]);
      await _flush();
      // Nothing to assert other than no crash; the editor's dispose path
      // having run is sufficient.
    });

    test('inject() routes through the backend', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      ed.inject(ControlKey(ControlCode.ctrlC));
      expect(input.injected, [ControlKey(ControlCode.ctrlC)]);
      ed.close();
    });

    test('SIGINT-style inject(Ctrl-C) clears the draft; typing continues',
        () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      final f = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('a'));
      input.emit(CharInput('b'));
      ed.inject(ControlKey(ControlCode.ctrlC)); // clears the draft
      input.emit(CharInput('x'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await f, 'x');
      ed.close();
    });

    test('events from backend interleave with inject() calls', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      final f = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('a'));
      ed.inject(CharInput('B'));
      input.emit(CharInput('c'));
      input.emit(ControlKey(ControlCode.enter));
      expect(await f, 'aBc');
      ed.close();
    });
  });

  group('LineEditor.readKey', () {
    test('returns CharInput for ASCII keypress', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final fut = ed.readKey();
      input.emit(CharInput('y'));
      final got = await fut;
      expect(got, isA<CharInput>());
      expect((got as CharInput).text, 'y');
      ed.close();
    });

    test('returns EscapeKey when ESC is pressed', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final fut = ed.readKey();
      input.emit(EscapeKey());
      expect(await fut, isA<EscapeKey>());
      ed.close();
    });

    test('readKey completes with Ctrl-C on a confirmed quit, not the arm',
        () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final fut = ed.readKey();
      input.emit(ControlKey(ControlCode.ctrlC)); // arm
      var resolved = false;
      fut.then((_) => resolved = true);
      await _flush();
      expect(resolved, isFalse, reason: 'the first press only arms the confirm');
      input.emit(ControlKey(ControlCode.ctrlC)); // confirm quit
      final got = await fut;
      expect(got, isA<ControlKey>());
      expect((got as ControlKey).code, ControlCode.ctrlC);
      ed.close();
    });

    test('returns ArrowKey for arrow keys', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final fut = ed.readKey();
      input.emit(ArrowKey(ArrowDirection.up));
      final got = await fut;
      expect(got, isA<ArrowKey>());
      expect((got as ArrowKey).direction, ArrowDirection.up);
      ed.close();
    });
  });

  group('LineEditor queue mode (event-based dispatch)', () {
    test('CharInput with multi-character text inserts atomically', () async {
      // E.g. a notcurses backend or UTF-8 grapheme cluster might deliver
      // 'é' as a single CharInput.
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      input.emit(CharInput('é'));
      input.emit(CharInput('è'));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();
      expect(submitted, ['éè']);
      ed.endCancelMonitor();
      ed.close();
    });

    test('Backspace event removes last char', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      input.emit(CharInput('a'));
      input.emit(CharInput('b'));
      input.emit(ControlKey(ControlCode.backspace));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();
      expect(submitted, ['a']);
      ed.endCancelMonitor();
      ed.close();
    });

    test('AltKey / FunctionKey / UnknownEscape are ignored; arrows edit',
        () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final submitted = <String>[];
      var cancelled = false;
      ed.beginCancelMonitor(
        () => cancelled = true,
        onQueueSubmit: submitted.add,
      );
      // These must NOT crash and must NOT submit anything.
      input.emit(AltKey(0x66));
      input.emit(FunctionKey(FunctionKeyCode.f1));
      input.emit(UnknownEscape([0x1b, 0x4f, 0x30]));
      // Motion keys now edit the queued draft (tin-m8r3) instead of being
      // dropped: left arrow steps a char, Home parks at column 0.
      input.emit(CharInput('a'));
      input.emit(CharInput('b'));
      input.emit(ArrowKey(ArrowDirection.left));
      input.emit(EditingKey(EditingAction.home));
      input.emit(CharInput('X'));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();
      expect(submitted, ['Xab'],
          reason:
              'Left+Home moved the cursor before X landed — with the old '
              'drop-through it would be "abX"');
      expect(cancelled, isFalse);
      ed.endCancelMonitor();
      ed.close();
    });

    test('Tab / Ctrl-L / Ctrl-D are ignored in queue mode', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      input.emit(CharInput('h'));
      input.emit(ControlKey(ControlCode.tab));
      input.emit(ControlKey(ControlCode.ctrlL));
      input.emit(ControlKey(ControlCode.ctrlD));
      input.emit(CharInput('i'));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();
      expect(submitted, ['hi']);
      ed.endCancelMonitor();
      ed.close();
    });

    test('ESC with empty buffer fires cancel; with non-empty clears', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      var cancelled = false;
      final submitted = <String>[];
      ed.beginCancelMonitor(
        () => cancelled = true,
        onQueueSubmit: submitted.add,
      );
      // Non-empty buffer: ESC clears it.
      input.emit(CharInput('a'));
      input.emit(EscapeKey());
      expect(cancelled, isFalse);
      // Now empty: ESC cancels.
      input.emit(EscapeKey());
      expect(cancelled, isTrue);
      ed.endCancelMonitor();
      ed.close();
    });

    group('input capture window (tin-y8kh)', () {
      test('echoes chars, submits on Enter, stays armed for multi-entry',
          () async {
        final input = FakeInputBackend();
        final ed = _makeEditor(input);
        final f = ed.readLine('> '); // subscribe the backend
        await _flush();
        input.emit(ControlKey(ControlCode.enter));
        expect(await f, isEmpty); // finish the readLine the way a submit does
        await _flush();
        final submitted = <String>[];
        ed.beginInputCaptureWindow(submitted.add);
        input.emit(CharInput('a'));
        input.emit(CharInput('b'));
        input.emit(ControlKey(ControlCode.enter));
        await _flush();
        expect(submitted, ['ab'],
            reason: 'Enter during capture submits the draft');
        // Multi-entry: capture stays armed after the submit.
        input.emit(CharInput('c'));
        input.emit(ControlKey(ControlCode.enter));
        await _flush();
        expect(submitted, ['ab', 'c'],
            reason: 'Enter keeps the capture armed so lines can stack');
        ed.endInputCaptureWindow();
        ed.close();
      });

      test('end closes the window; later keys are dropped, not captured',
          () async {
        final input = FakeInputBackend();
        final ed = _makeEditor(input);
        final f = ed.readLine('> ');
        await _flush();
        input.emit(ControlKey(ControlCode.enter));
        expect(await f, isEmpty);
        await _flush();
        final submitted = <String>[];
        ed.beginInputCaptureWindow(submitted.add);
        input.emit(CharInput('x'));
        ed.endInputCaptureWindow();
        // After the window ends there is no readLine and no capture — the
        // ownerless guard (tin-y27w) drops keystrokes, so nothing is captured
        // and nothing waits for the next readLine.
        input.emit(CharInput('y'));
        input.emit(ControlKey(ControlCode.enter));
        await _flush();
        expect(submitted, isEmpty, reason: 'the window was ended before Enter');
        ed.close();
      });

      test('a readKey armed during capture answers, then capture resumes',
          () async {
        final input = FakeInputBackend();
        final ed = _makeEditor(input);
        final f = ed.readLine('> ');
        await _flush();
        input.emit(ControlKey(ControlCode.enter));
        expect(await f, isEmpty);
        await _flush();
        final submitted = <String>[];
        ed.beginInputCaptureWindow(submitted.add);
        // The host arms an approval prompt mid-window (readKey saves and
        // restores the cancel-monitor, so capture survives the prompt).
        final key = ed.readKey(globalKeys: true);
        await _flush();
        input.emit(CharInput('y'));
        await _flush();
        expect(await key, isA<CharInput>(),
            reason: 'the prompt owns the keyboard while it is armed');
        // Completing a readKey opens a 10ms paste-burst window during which
        // CharInput is queued as overflow (never dispatched) — wait it out
        // before the resumed-capture keystrokes, the way a human hand does.
        await Future<void>.delayed(const Duration(milliseconds: 15));
        // Capture restored: typing + Enter still submits.
        input.emit(CharInput('z'));
        input.emit(ControlKey(ControlCode.enter));
        await _flush();
        expect(submitted, ['z'], reason: 'capture must survive a nested readKey');
        ed.endInputCaptureWindow();
        ed.close();
      });

      test('an empty window keeps the prompt row painted', () async {
        final io = FakeStdio();
        final input = FakeInputBackend();
        final ed = _makeEditor(input, io: io);
        final f = ed.readLine('> '); // subscribe the backend
        await _flush();
        input.emit(ControlKey(ControlCode.enter));
        expect(await f, isEmpty); // finish the readLine the way a submit does
        await _flush();

        // Begin an empty capture window (the mid-/compact state): the input
        // row must still show a prompt — pre-fix it was cleared, blanking the
        // row until the dispatch settled and readLine re-armed.
        final vt = VirtualTerminal(width: 80, height: 24);
        ed.beginInputCaptureWindow((_) {});
        vt.feed(io.written.toString());
        final row = vt.rowText(vt.cursorRow);
        expect(row, contains('>'),
            reason: 'the empty capture window must keep a prompt painted');
        final promptRow = vt.cursorRow;
        io.written.clear();

        // Ending the window with nothing typed must not blank the row either
        // (no flash between window end and the next readLine arming).
        ed.endInputCaptureWindow();
        vt.feed(io.written.toString());
        expect(vt.cursorRow, promptRow,
            reason: 'the cursor stays parked on the input row');
        expect(vt.rowText(vt.cursorRow), contains('>'),
            reason: 'window end must not erase the prompt');
        ed.close();
      });
    });
  });
}
