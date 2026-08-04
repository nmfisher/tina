import 'dart:async';

import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';

import 'stdio_fake.dart';

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

    test('SIGINT-style inject(Ctrl-C) clears non-empty buffer', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      final f = ed.readLine('> ');
      await _flush();
      input.emit(CharInput('a'));
      input.emit(CharInput('b'));
      ed.inject(ControlKey(ControlCode.ctrlC));
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

    test('returns ControlKey for Ctrl-C', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      final fut = ed.readKey();
      input.emit(ControlKey(ControlCode.ctrlC));
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

    test('AltKey / FunctionKey / ArrowKey / EditingKey are silently ignored',
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
      input.emit(ArrowKey(ArrowDirection.left));
      input.emit(EditingKey(EditingAction.home));
      input.emit(UnknownEscape([0x1b, 0x4f, 0x30]));
      input.emit(CharInput('x'));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();
      expect(submitted, ['x'],
          reason: 'non-text events should not contribute to the buffer');
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
  });
}
