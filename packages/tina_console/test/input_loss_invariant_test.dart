import 'dart:async';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:test/test.dart';
import 'package:tina_console/src/backend/notcurses_input_backend.dart';
import 'package:tina_console/tina_console.dart';

import 'line_editor_input_backend_test.dart' show FakeInputBackend;
import 'stdio_fake.dart';

/// Regression seam for the "typing dies mid-session, ctrl+C still quits" bug
/// class (tin-DEAD-KEYBOARD). SIGINT is handled OUTSIDE the input path
/// (`ProcessSignal.sigint.watch()` injects straight into the editor), so a
/// live ctrl+C proves only that the Dart event loop runs — everything
/// upstream (tty → native pump → backend) can be dead.
///
/// [LineEditor.keyCount] increments exactly once per event delivered to the
/// editor's handler. These tests pin the two halves of the invariant:
///
///   1. every event that enters the editor advances keyCount by exactly one;
///   2. events pushed through the REAL backend path (fake key source →
///      NotcursesInputBackend → editor stream) arrive 1:1 — no silent loss.
///
/// If keyCount advances but the screen is dead, the bug is downstream of the
/// editor (rendering). If keyCount freezes while the user types, the bug is
/// upstream of the editor — the exact blind spot `stuck_check.dart` cannot
/// see (it requires keyCount to ADVANCE to fire).
class _FakeKeySource implements KeySource {
  final List<NcKeyEvent> _events = [];

  void add(int id) => _events.add(NcKeyEvent(id, false, false, false));

  @override
  NcKeyEvent? poll() => _events.isEmpty ? null : _events.removeAt(0);

  @override
  void disposeKey(NcKeyEvent key) {}
}

/// Deterministic stopwatch (mirrors notcurses_input_backend_test).
class _ManualStopwatch extends Stopwatch {
  Duration _elapsed = Duration.zero;

  @override
  Duration get elapsed => _elapsed;
  @override
  int get elapsedMicroseconds => _elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => _elapsed.inMilliseconds;
  @override
  int get elapsedTicks => _elapsed.inMicroseconds;

  void elapse(Duration d) => _elapsed += d;
}

Future<void> _flush() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.microtask(() {});
  }
  await Future<void>.delayed(Duration.zero);
}

/// Same pump the backend tests use: events deferred by _emit (all-but-first
/// per tick) land in the editor's subscription.
Future<void> _pumpMicrotasks() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

LineEditor _makeEditor(InputBackend input, {FakeStdio? io}) {
  final stdio = io ?? FakeStdio();
  final screen = Screen(
    io: stdio,
    layout: ScreenLayout.fromSize(80, 24),
    ansi: AnsiCapable.no,
  );
  return LineEditor(
    screen: screen,
    input: input,
    escapeTimeout: Duration.zero,
  );
}

void main() {
  group('input-loss invariant: one delivered event == one keyCount tick', () {
    test('every event during an active readLine advances keyCount by one',
        () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      final line = ed.readLine('> ');
      await _flush();

      input.emit(CharInput('h'));
      input.emit(CharInput('i'));
      input.emit(EscapeKey());
      input.emit(ControlKey(ControlCode.ctrlR));
      input.emit(CharInput('!'));
      await _flush();

      expect(ed.keyCount, 5,
          reason: '5 delivered events must tick keyCount 5×');
      input.emit(ControlKey(ControlCode.enter));
      expect(await line, 'hi!');
      ed.close();
    });

    test(
        'events while no readLine is armed still advance keyCount '
        '(cancel monitor keeps the editor listening)', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      var cancels = 0;
      ed.beginCancelMonitor(() => cancels++);
      await _flush();

      input.emit(CharInput('a'));
      input.emit(CharInput('b'));
      input.emit(CharInput('c'));
      await _flush();

      expect(ed.keyCount, 3,
          reason: 'an idle-looking editor (monitor armed) still counts keys; '
              'a frozen keyCount here means the stream upstream died');
      expect(cancels, 0);
      ed.endCancelMonitor();
      ed.close();
    });

    test('queue-mode keystrokes advance keyCount and are captured', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      final submitted = <String>[];
      ed.beginCancelMonitor(() {}, onQueueSubmit: submitted.add);
      await _flush();

      input.emit(CharInput('x'));
      input.emit(CharInput('y'));
      input.emit(ControlKey(ControlCode.enter));
      await _flush();

      expect(ed.keyCount, 3);
      expect(submitted, ['xy'],
          reason: 'queue mode must not silently drop typed text');
      ed.endCancelMonitor();
      ed.close();
    });

    test('no events delivered → keyCount never moves (control)', () async {
      final input = FakeInputBackend();
      final ed = _makeEditor(input);
      ed.readLine('> ');
      await _flush();
      await _pumpMicrotasks();

      expect(ed.keyCount, 0);
      ed.close();
    });
  });

  group('input-loss invariant through the real backend path (pump)', () {
    // The pump path is production's path: input_pump.c → _onPumpedInput →
    // editor. (The legacy poll path is NOT exercised here — production does
    // not use it. It used to crash on Enter: translateNcKey fed NcKey.enter
    // (1115121) to String.fromCharCode, a RangeError, whenever the native
    // keySynthesizedP() reported false. translateNcKey now derives
    // synthesized-ness from the id, so that path is total too; see
    // notcurses_translate_key_test's preterunicode cases.)

    test('N keys at the key source → N events → keyCount +N', () async {
      final source = _FakeKeySource();
      final backend = NotcursesInputBackend(
        source,
        startupDrainMinWindow: Duration.zero,
        startPolling: false,
        temporalPasteDetection: false,
        replySequenceFiltering: false,
      );
      addTearDown(backend.dispose);

      // The editor listens to the real backend directly.
      final ed = _makeEditor(backend);
      final line = ed.readLine('> ');
      await _flush();

      for (var i = 0; i < 7; i++) {
        backend.pumpedInputForTest('a'.codeUnitAt(0));
      }
      backend.pumpedInputForTest(nc.NcKey.enter);
      await _pumpMicrotasks();

      expect(ed.keyCount, 8,
          reason: '8 keys entered the backend; all 8 must reach the editor. '
              'A shortfall here is the upstream loss the live bug shows.');
      expect(await line, 'aaaaaaa');
      ed.close();
    });

    test(
        'keys swallowed by the startup drain never tick keyCount; the '
        'window is bounded', () async {
      final clock = _ManualStopwatch();
      final source = _FakeKeySource();
      final backend = NotcursesInputBackend(
        source,
        startupDrainMinWindow: const Duration(seconds: 10),
        startPolling: false,
        temporalPasteDetection: false,
        replySequenceFiltering: false,
        clock: clock,
      );
      addTearDown(backend.dispose);

      // The editor listens to the real backend directly.
      final ed = _makeEditor(backend);
      final line = ed.readLine('> ');
      await _flush();

      backend.pumpedInputForTest('q'.codeUnitAt(0));
      backend.pumpedInputForTest('w'.codeUnitAt(0));
      await _pumpMicrotasks();
      expect(ed.keyCount, 0,
          reason: 'post-init reply noise is drained on purpose; these keys '
              'are gone by design');

      // Once the drain window expires the very next keystroke flows again —
      // the loss window must be bounded, never permanent.
      clock.elapse(const Duration(seconds: 10));
      backend.pumpedInputForTest('z'.codeUnitAt(0));
      await _pumpMicrotasks();
      expect(ed.keyCount, 1,
          reason: 'an unbounded drain would be a dead keyboard by design');

      backend.pumpedInputForTest(nc.NcKey.enter);
      await _pumpMicrotasks();
      expect(await line, 'z');
      ed.close();
    });

    test('a burst of 40 rapid keys loses nothing end to end', () async {
      final source = _FakeKeySource();
      final backend = NotcursesInputBackend(
        source,
        startupDrainMinWindow: Duration.zero,
        startPolling: false,
        temporalPasteDetection: false,
        replySequenceFiltering: false,
      );
      addTearDown(backend.dispose);

      // The editor listens to the real backend directly.
      final ed = _makeEditor(backend);
      final line = ed.readLine('> ');
      await _flush();

      const n = 40;
      for (var i = 0; i < n; i++) {
        backend.pumpedInputForTest('k'.codeUnitAt(0));
      }
      backend.pumpedInputForTest(nc.NcKey.enter);
      await _pumpMicrotasks();

      expect(ed.keyCount, n + 1,
          reason: 'burst/deferral machinery must reorder, never drop');
      expect(await line, 'k' * n);
      ed.close();
    });
  });
}
