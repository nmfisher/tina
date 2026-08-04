import 'dart:async';

import 'package:tina_console/src/backend/notcurses_input_backend.dart';
import 'package:tina_console/src/backend/paste_burst_detector.dart';
import 'package:tina_console/src/input_event.dart';
import 'package:tina_console/src/input_latency.dart';
import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:test/test.dart';

/// Deterministic stopwatch that only advances when [elapse] is called.
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

/// Pump the microtask queue so events deferred by [NotcursesInputBackend._emit]
/// (all-but-first per tick) land in the captured stream.
Future<void> pumpMicrotasks() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeKeySource implements KeySource {
  final List<NcKeyEvent> _events = [];

  void add(int id) {
    _events.add(NcKeyEvent(id, false, false, false));
  }

  void addSynthesized(int id) {
    _events.add(NcKeyEvent(id, false, false, true));
  }

  @override
  NcKeyEvent? poll() => _events.isEmpty ? null : _events.removeAt(0);

  @override
  void disposeKey(NcKeyEvent key) {}
}

void main() {
  group('StartupDrain', () {
    late _ManualStopwatch clock;

    setUp(() {
      clock = _ManualStopwatch();
    });

    StartupDrain makeDrain({
      Duration min = const Duration(milliseconds: 150),
      Duration max = const Duration(seconds: 1),
      Duration idle = const Duration(milliseconds: 30),
    }) =>
        StartupDrain(
          minWindow: min,
          maxWindow: max,
          idleThreshold: idle,
          clock: clock,
        );

    test('drains for the full minimum window when no events arrive', () {
      final drain = makeDrain();
      expect(drain.isDraining, isTrue);
      clock.elapse(const Duration(milliseconds: 149));
      expect(drain.isDraining, isTrue);
      clock.elapse(const Duration(milliseconds: 2));
      expect(drain.isDraining, isFalse);
    });

    test('stops immediately after minWindow when no event was ever seen', () {
      final drain = makeDrain();
      clock.elapse(const Duration(milliseconds: 150));
      expect(drain.isDraining, isFalse);
    });

    test('extends while events keep arriving within the idle threshold', () {
      final drain = makeDrain();
      clock.elapse(const Duration(milliseconds: 140));
      drain.sawEvent();
      clock.elapse(const Duration(milliseconds: 25));
      expect(drain.isDraining, isTrue);
      drain.sawEvent();
      clock.elapse(const Duration(milliseconds: 25));
      expect(drain.isDraining, isTrue);
      drain.sawEvent();
      // Still within idle threshold of the last event, but approaching max.
      clock.elapse(const Duration(milliseconds: 25));
      expect(drain.isDraining, isTrue);
    });

    test('stops after idle threshold once events stop arriving', () {
      final drain = makeDrain();
      clock.elapse(const Duration(milliseconds: 140));
      drain.sawEvent();
      clock.elapse(const Duration(milliseconds: 35));
      expect(drain.isDraining, isFalse);
    });

    test('hard-caps at the maximum window even if events keep arriving', () {
      final drain = makeDrain(max: const Duration(milliseconds: 200));
      for (var i = 0; i < 10; i++) {
        drain.sawEvent();
        clock.elapse(const Duration(milliseconds: 15));
      }
      expect(drain.isDraining, isTrue);
      clock.elapse(const Duration(milliseconds: 100));
      expect(drain.isDraining, isFalse);
    });
  });

  group('NotcursesInputBackend', () {
    late _FakeKeySource source;
    late _ManualStopwatch clock;
    late NotcursesInputBackend backend;
    late List<InputEvent> emitted;
    late StreamSubscription<InputEvent> sub;

    NotcursesInputBackend makeBackend({
      Duration? min,
      Duration? max,
      Duration? idle,
      PasteBurstDetector? burstDetector,
    }) {
      final b = NotcursesInputBackend(
        source,
        startupDrainMinWindow: min ?? const Duration(milliseconds: 150),
        startupDrainMaxWindow: max ?? const Duration(seconds: 1),
        startupDrainIdleThreshold: idle ?? const Duration(milliseconds: 30),
        clock: clock,
        startPolling: false,
        burstDetector: burstDetector,
      );
      sub = b.events.listen(emitted.add);
      return b;
    }

    setUp(() {
      source = _FakeKeySource();
      clock = _ManualStopwatch();
      emitted = [];
    });

    tearDown(() async {
      await sub.cancel();
      backend.dispose();
    });

    test('drains startup junk that arrives before minWindow', () {
      backend = makeBackend(min: const Duration(milliseconds: 50));
      source.add(0x1b); // ESC
      source.addSynthesized(0x11037a); // synthesized UP-like junk
      backend.pollForTest();
      expect(emitted, isEmpty);
      clock.elapse(const Duration(milliseconds: 60));
      backend.pollForTest();
      expect(emitted, isEmpty);
    });

    test('drains a delayed reply burst and forwards later real events',
        () async {
      backend = makeBackend(
        min: const Duration(milliseconds: 50),
        max: const Duration(milliseconds: 500),
        idle: const Duration(milliseconds: 30),
      );

      // First poll: nothing yet, drain stays open (clock just started).
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, isEmpty);

      // First terminal reply arrives within minWindow — drained.
      clock.elapse(const Duration(milliseconds: 40));
      source.addSynthesized(0x11037c); // NCKEY_DOWN-like junk
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, isEmpty,
          reason: 'reply within minWindow should be drained');

      // A late reply arrives just after minWindow, within idle threshold of
      // the previous one — still drained.
      clock.elapse(const Duration(milliseconds: 25));
      source.addSynthesized(0x11037a); // NCKEY_UP-like
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, isEmpty);

      // Idle long enough for the drain to close.
      clock.elapse(const Duration(milliseconds: 40));
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, isEmpty);

      // Now a real keypress should be forwarded. The burst detector buffers
      // it; pump past its join window so the next poll's expire() flushes it.
      source.add('x'.codeUnitAt(0));
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, isEmpty);
      clock.elapse(const Duration(milliseconds: 40));
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, [CharInput('x')]);
    });

    test('stops draining promptly when no events ever arrive', () async {
      backend = makeBackend(min: const Duration(milliseconds: 50));
      // Prime the drain clock (first poll starts the stopwatch).
      backend.pollForTest();
      await pumpMicrotasks();
      clock.elapse(const Duration(milliseconds: 60));
      backend.pollForTest();
      await pumpMicrotasks();
      source.add('a'.codeUnitAt(0));
      backend.pollForTest();
      await pumpMicrotasks();
      // Burst detector buffers the char; flush it via a gap > joinWindow.
      clock.elapse(const Duration(milliseconds: 40));
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, [CharInput('a')]);
    });

    test('translates events normally after the drain closes', () async {
      backend = makeBackend(min: const Duration(milliseconds: 10));
      // Prime + elapse past the (short) drain window so the drain is done.
      backend.pollForTest();
      await pumpMicrotasks();
      clock.elapse(const Duration(milliseconds: 20));
      backend.pollForTest();
      await pumpMicrotasks();
      source.add(0x0d); // Enter
      source.add('b'.codeUnitAt(0));
      backend.pollForTest();
      await pumpMicrotasks();
      // Both buffered; flush via a gap > joinWindow. Below minPasteChars, so
      // they emit individually in arrival order.
      clock.elapse(const Duration(milliseconds: 40));
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, [
        ControlKey(ControlCode.enter),
        CharInput('b'),
      ]);
    });

    test('burst detector receives events after drain closes', () async {
      final detector = PasteBurstDetector(
        joinWindow: const Duration(milliseconds: 50),
        minPasteChars: 2,
      );
      backend = makeBackend(
        min: const Duration(milliseconds: 10),
        burstDetector: detector,
      );
      // Prime + elapse past the drain window.
      backend.pollForTest();
      await pumpMicrotasks();
      clock.elapse(const Duration(milliseconds: 20));
      backend.pollForTest();
      await pumpMicrotasks();

      // Two chars within the detector window get buffered (not emitted yet).
      source.add('h'.codeUnitAt(0));
      source.add('i'.codeUnitAt(0));
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, isEmpty);

      // Advance past the join window; the next poll's expire() flushes the
      // burst as a single PasteInput.
      clock.elapse(const Duration(milliseconds: 60));
      backend.pollForTest();
      await pumpMicrotasks();
      expect(emitted, [PasteInput('hi')]);
    });

    test('event-driven mode emits an ordinary key immediately', () async {
      backend = NotcursesInputBackend(
        source,
        startupDrainMinWindow: Duration.zero,
        clock: clock,
        startPolling: false,
        temporalPasteDetection: false,
      );
      sub = backend.events.listen(emitted.add);
      backend.pollForTest();

      backend.pumpedInputForTest('q'.codeUnitAt(0));

      expect(emitted, [CharInput('q')]);
    });

    test('explicit native paste markers preserve multiline content', () async {
      backend = NotcursesInputBackend(
        source,
        startupDrainMinWindow: Duration.zero,
        clock: clock,
        startPolling: false,
        temporalPasteDetection: false,
      );
      sub = backend.events.listen(emitted.add);
      backend.pollForTest();

      backend.pumpedInputForTest(nc.NcKey.pasteBegin);
      for (final unit in 'one'.codeUnits) {
        backend.pumpedInputForTest(unit);
      }
      backend.pumpedInputForTest(nc.NcKey.enter);
      for (final unit in 'two'.codeUnits) {
        backend.pumpedInputForTest(unit);
      }
      backend.pumpedInputForTest(nc.NcKey.pasteEnd);

      expect(emitted, [PasteInput('one\ntwo')]);
    });
  });

  // Phase 6: the native pump batches records per native→Dart notification.
  // dartCallbackBatches counts notifications (one per batch); nativeEvents
  // counts records. A single-key batch has batches == events == 1; a multi-record
  // batch has batches == 1 and events == N.
  group('batched pump counters', () {
    late NotcursesInputBackend backend;
    late StreamSubscription sub;
    final emitted = <InputEvent>[];

    setUpAll(InputLatency.forceEnable);

    setUp(() {
      InputLatency.reset();
      emitted.clear();
      backend = NotcursesInputBackend(
        _FakeKeySource(),
        startupDrainMinWindow: Duration.zero,
        startPolling: false,
        temporalPasteDetection: false,
      );
      sub = backend.events.listen(emitted.add);
    });

    tearDown(() {
      sub.cancel();
      backend.dispose();
    });

    test('single record: dartCallbackBatches == nativeEvents == 1', () async {
      backend.pumpedInputForTest('q'.codeUnitAt(0));
      await pumpMicrotasks();
      expect(emitted, [CharInput('q')]);
      expect(OpCounters.instance.nativeEvents, 1);
      expect(OpCounters.instance.dartCallbackBatches, 1);
    });

    test('multi-record batch: one batch, N records', () async {
      final batch = 'hello'.codeUnits
          .map((id) => nc.PumpedInput(id, 0, 0))
          .toList();
      backend.pumpedBatchForTest(batch);
      await pumpMicrotasks();
      expect(emitted, hasLength(5));
      expect(OpCounters.instance.nativeEvents, 5,
          reason: 'nativeEvents counts records, one per PumpedInput');
      expect(OpCounters.instance.dartCallbackBatches, 1,
          reason: 'one batch (one drain), not one per record');
    });

    test('two batches: dartCallbackBatches == 2, nativeEvents == sum',
        () async {
      backend.pumpedBatchForTest(
          'ab'.codeUnits.map((id) => nc.PumpedInput(id, 0, 0)).toList());
      await pumpMicrotasks();
      backend.pumpedBatchForTest(
          'cde'.codeUnits.map((id) => nc.PumpedInput(id, 0, 0)).toList());
      await pumpMicrotasks();
      expect(OpCounters.instance.nativeEvents, 5);
      expect(OpCounters.instance.dartCallbackBatches, 2);
    });

    test('empty batch is a no-op (no spurious batch count)', () {
      backend.pumpedBatchForTest(const []);
      expect(OpCounters.instance.dartCallbackBatches, 0);
      expect(OpCounters.instance.nativeEvents, 0);
    });
  });

  // Regression guard for the paste-detection bug: the live notcurses path uses
  // temporal burst detection on the EVENT-DRIVEN pump (not the polling path).
  // A paste's events arrive in one tight batch; without the pump-path flush
  // timer the burst would sit buffered until the next keystroke. These drive
  // pumpedBatchForTest (the pump path) with temporalPasteDetection: true — the
  // combination no pre-existing test exercised (all temporal tests use
  // pollForTest). Real Timer + real Stopwatch, since the flush rides a Timer.
  group('pump-path temporal paste detection', () {
    late NotcursesInputBackend backend;
    late List<InputEvent> emitted;
    late StreamSubscription<InputEvent> sub;

    // Short joinWindow so the flush fires quickly in tests.
    final detector = PasteBurstDetector(
      joinWindow: const Duration(milliseconds: 30),
      minPasteChars: 4,
    );

    setUp(() {
      emitted = [];
      backend = NotcursesInputBackend(
        _FakeKeySource(),
        startupDrainMinWindow: Duration.zero,
        startPolling: false,
        temporalPasteDetection: true,
        burstDetector: detector,
        // Real, started clock so _nowMicros advances for expire()'s gap check.
        clock: Stopwatch()..start(),
      );
      sub = backend.events.listen(emitted.add);
      backend.pollForTest();
    });

    tearDown(() async {
      await sub.cancel();
      backend.dispose();
    });

    nc.PumpedInput rec(int id) => nc.PumpedInput(id, 0, 0);

    test('multi-line paste collapses to one PasteInput', () async {
      backend.pumpedBatchForTest([
        ...'one'.codeUnits.map(rec),
        rec(nc.NcKey.enter),
        ...'two'.codeUnits.map(rec),
        rec(nc.NcKey.enter),
        ...'three'.codeUnits.map(rec),
      ]);
      // Buffered immediately; nothing emitted yet.
      await pumpMicrotasks();
      expect(emitted, isEmpty);
      // Just past the armed flush (joinWindow + 1ms = 31ms). Waiting close to
      // the boundary catches an off-by-one in the timer duration: expire() uses
      // a strict `>` gap check, so a timer armed at exactly joinWindow would
      // fire with gap == joinWindow (not >) and fail to flush.
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(emitted, [PasteInput('one\ntwo\nthree')]);
    });

    test('paste flushes without a subsequent keystroke', () async {
      // The core regression: the burst MUST flush on its own (via the timer),
      // not only when the next keystroke's add() flushes the prior burst.
      backend.pumpedBatchForTest([
        ...'hello world'.codeUnits.map(rec),
      ]);
      await pumpMicrotasks();
      expect(emitted, isEmpty, reason: 'burst should buffer, not emit inline');
      // No further input — the flush must come from the timer alone. Just past
      // the armed boundary (31ms) to exercise the strict-`>` edge.
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(emitted, [PasteInput('hello world')],
          reason: 'flush timer must fire without a next keystroke');
    });

    test('single keystroke emits promptly (not held, not inflated to paste)',
        () async {
      backend.pumpedBatchForTest([rec('q'.codeUnitAt(0))]);
      await pumpMicrotasks();
      expect(emitted, isEmpty, reason: 'buffered until flush');
      await Future<void>.delayed(const Duration(milliseconds: 35));
      // Below minPasteChars → emitted as the individual CharInput, not a paste.
      expect(emitted, [CharInput('q')]);
    });
  });
}
