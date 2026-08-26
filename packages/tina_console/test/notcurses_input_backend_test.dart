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

  // tin-v6tq: terminal capability replies that survive past the startup
  // drain surface as ESC + printable key events. The backend drops them at
  // the pump layer, ahead of the paste-burst detector, so they never reach
  // the editor as pasted garbage — while genuine pastes, typing and a lone
  // ESC (cancel) all still arrive.
  group('pump-path reply filtering (tin-v6tq)', () {
    late NotcursesInputBackend backend;
    late List<InputEvent> emitted;
    late StreamSubscription<InputEvent> sub;

    // A real, started clock: the filter compares per-record timestamps, and
    // the ESC-release path rides a real Timer.
    late Stopwatch clock;

    NotcursesInputBackend makeBackend({
      bool temporalPasteDetection = false,
      PasteBurstDetector? burstDetector,
      bool replySequenceFiltering = true,
    }) {
      final b = NotcursesInputBackend(
        _FakeKeySource(),
        startupDrainMinWindow: Duration.zero,
        startPolling: false,
        clock: clock,
        temporalPasteDetection: temporalPasteDetection,
        burstDetector: burstDetector,
        replySequenceFiltering: replySequenceFiltering,
      );
      sub = b.events.listen(emitted.add);
      return b;
    }

    setUp(() {
      emitted = [];
      clock = Stopwatch()..start();
    });

    tearDown(() async {
      await sub.cancel();
      backend.dispose();
    });

    int recId(String s) => s.codeUnits.first;

    // The reply bundle tool/tmux_inject_replies.sh replays, as pump records
    // (ESC + printable bytes; notcurses emits the ESC standalone and decodes
    // the rest as ordinary characters).
    List<nc.PumpedInput> bundleRecords() => [
          for (final s in [
            '\x1b[?62;c',
            '\x1b[1;1R',
            '\x1b]4;1;rgb:8000/0000/0000\x1b\\',
            '\x1b]10;rgb:ffff/ffff/ffff\x1b\\',
            '\x1b]11;rgb:0000/0000/0000\x1b\\',
            '\x1b[?2026;1\$y',
            '\x1b[?1016;1\$y',
            '\x1b[?1;3;256S',
            '\x1b[?1u',
            '\x1b_Gi=1;OK\x1b\\',
            '\x1bP1+r544e;787465726d2d323536636f6c6f72\x1b\\',
            '\x1b[4;1;1;80;120t',
            '\x1b[8;40;120t',
          ])
            for (final ch in s.codeUnits) nc.PumpedInput(ch, 0, 0),
        ];

    test('a mid-run reply burst produces no input events at all', () async {
      backend = makeBackend();
      backend.pumpedBatchForTest(bundleRecords());
      await pumpMicrotasks();
      expect(emitted, isEmpty,
          reason: 'no reply byte may reach the editor, as chars or a paste');
      // Nothing arrives late either (no held state, no straggler timer).
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(emitted, isEmpty);
    });

    test('a bursty reply stream with >30ms gaps is still discarded', () async {
      // The ticket's drain-window acceptance case: replies keep arriving
      // inside the first second but with gaps wider than StartupDrain's
      // 30ms idle threshold, so the drain closes — and the filter, not the
      // drain, must keep discarding every complete reply that follows.
      backend = NotcursesInputBackend(
        _FakeKeySource(),
        startupDrainMinWindow: const Duration(milliseconds: 150),
        startupDrainMaxWindow: const Duration(seconds: 1),
        startupDrainIdleThreshold: const Duration(milliseconds: 30),
        clock: clock,
        startPolling: false,
        temporalPasteDetection: false,
      );
      sub = backend.events.listen(emitted.add);

      // First reply inside minWindow: drained by StartupDrain.
      backend.pumpedBatchForTest(
        [for (final ch in '\x1b[?62;c'.codeUnits) nc.PumpedInput(ch, 0, 0)],
      );
      await pumpMicrotasks();
      expect(emitted, isEmpty);

      // >30ms later the drain has closed (idle threshold exceeded, no event
      // kept it open). Each further reply is complete, so the filter swallows
      // it whole — a gap between replies must not leak either of them.
      for (final reply in [
        '\x1b]4;1;rgb:8000/0000/0000\x1b\\',
        '\x1b[?2026;1\$y',
        '\x1b[8;40;120t',
      ]) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        backend.pumpedBatchForTest(
          [for (final ch in reply.codeUnits) nc.PumpedInput(ch, 0, 0)],
        );
      }
      await pumpMicrotasks();
      expect(emitted, isEmpty,
          reason: 'replies past the drain window must not reach the app');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(emitted, isEmpty);
    });

    test('an OSC reply split across the drain boundary leaves no fragment (tin-k7tr)',
        () async {
      // The --resume shape: the drain window closes between two records of
      // one reply. The head (ESC + introducer + payload start) is drained;
      // the tail arrives after the boundary. The filter must have kept its
      // mid-reply state across the boundary and swallow the tail — observed
      // leaking as `[Pasted text : 23 chars]` (`;154;rgb:afff/ffff/ff00`).
      backend = NotcursesInputBackend(
        _FakeKeySource(),
        startupDrainMinWindow: const Duration(milliseconds: 150),
        startupDrainMaxWindow: const Duration(seconds: 1),
        startupDrainIdleThreshold: const Duration(milliseconds: 30),
        startPolling: false,
        clock: clock,
        temporalPasteDetection: true,
        burstDetector: PasteBurstDetector(
          joinWindow: const Duration(milliseconds: 30),
          minPasteChars: 8,
        ),
      );
      sub = backend.events.listen(emitted.add);

      // Head of the OSC 4 palette reply, inside the drain window.
      backend.pumpedBatchForTest(
        [for (final ch in '\x1b]4;154;rgb:'.codeUnits) nc.PumpedInput(ch, 0, 0)],
      );
      await pumpMicrotasks();
      expect(emitted, isEmpty, reason: 'the drain owns the head');

      // Past minWindow + idleThreshold: the drain has closed. The tail —
      // all printable, ≥ minPasteChars — is exactly what the burst detector
      // would join into a paste if the filter let it through.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      backend.pumpedBatchForTest(
        [for (final ch in 'afff/ffff/ff00\x1b\\'.codeUnits) nc.PumpedInput(ch, 0, 0)],
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(emitted, isEmpty,
          reason: 'a boundary-split reply tail must not reach the editor');
    });

    test('a CSI reply split across the drain boundary leaves no fragment (tin-k7tr)',
        () async {
      backend = NotcursesInputBackend(
        _FakeKeySource(),
        startupDrainMinWindow: const Duration(milliseconds: 150),
        startupDrainMaxWindow: const Duration(seconds: 1),
        startupDrainIdleThreshold: const Duration(milliseconds: 30),
        startPolling: false,
        clock: clock,
        temporalPasteDetection: true,
        burstDetector: PasteBurstDetector(
          joinWindow: const Duration(milliseconds: 30),
          minPasteChars: 8,
        ),
      );
      sub = backend.events.listen(emitted.add);

      // Head of a DECRPM reply, drained; the `1$y` tail lands post-boundary.
      backend.pumpedBatchForTest(
        [for (final ch in '\x1b[?2026;'.codeUnits) nc.PumpedInput(ch, 0, 0)],
      );
      await pumpMicrotasks();
      expect(emitted, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      backend.pumpedBatchForTest(
        [for (final ch in '1\$y'.codeUnits) nc.PumpedInput(ch, 0, 0)],
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(emitted, isEmpty,
          reason: 'the CSI tail (3 printables) must be swallowed, not typed');
    });

    test('a drained lone ESC is not replayed after the boundary', () async {
      backend = NotcursesInputBackend(
        _FakeKeySource(),
        startupDrainMinWindow: const Duration(milliseconds: 150),
        startupDrainMaxWindow: const Duration(seconds: 1),
        startupDrainIdleThreshold: const Duration(milliseconds: 30),
        startPolling: false,
        clock: clock,
        temporalPasteDetection: false,
      );
      sub = backend.events.listen(emitted.add);

      // A real Escape pressed inside the drain window: drained (the drain's
      // documented trade-off), but fed to the filter, which holds it.
      backend.pumpedInputForTest(0x1b);
      await pumpMicrotasks();
      expect(emitted, isEmpty);

      // Drain closes; typing follows. The stale held ESC must NOT precede
      // the keystroke — it was already consumed by the drain.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      backend.pumpedInputForTest('q'.codeUnitAt(0));
      await pumpMicrotasks();
      expect(emitted, [CharInput('q')],
          reason: 'no stale EscapeKey may be replayed from inside the drain');
    });

    test('typing right after a burst arrives normally', () async {
      backend = makeBackend();
      backend.pumpedBatchForTest(bundleRecords());
      await pumpMicrotasks();
      for (final ch in 'yes'.codeUnits) {
        backend.pumpedInputForTest(ch);
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
      await pumpMicrotasks();
      expect(emitted, [CharInput('y'), CharInput('e'), CharInput('s')]);
    });

    test('a genuine paste right after a burst arrives whole', () async {
      backend = makeBackend(
        temporalPasteDetection: true,
        burstDetector: PasteBurstDetector(
          joinWindow: const Duration(milliseconds: 30),
          minPasteChars: 8,
        ),
      );
      backend.pumpedBatchForTest(bundleRecords());
      await pumpMicrotasks();
      const paste = 'The quick brown fox jumps over the lazy dog. ';
      backend.pumpedBatchForTest(
        [for (final ch in (paste * 10).codeUnits) nc.PumpedInput(ch, 0, 0)],
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(emitted, [PasteInput(paste * 10)],
          reason: 'a paste (no ESC events) must pass the reply filter verbatim');
    });

    test('a lone ESC is released without a following keystroke', () async {
      backend = makeBackend();
      backend.pumpedInputForTest(0x1b);
      await pumpMicrotasks();
      expect(emitted, isEmpty, reason: 'held pending a possible introducer');
      // Past introducerWindow (5 ms) + 1 ms. No further input arrives — the
      // release timer alone must deliver the Escape.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emitted, hasLength(1),
          reason: 'ESC cancel must not wait for the next keystroke');
      expect(emitted.single, isA<EscapeKey>());
    });

    test('ESC then a late keystroke delivers both, in order', () async {
      backend = makeBackend();
      backend.pumpedInputForTest(0x1b);
      await Future<void>.delayed(const Duration(milliseconds: 12));
      backend.pumpedInputForTest('q'.codeUnitAt(0));
      await pumpMicrotasks();
      expect(emitted, hasLength(2));
      expect(emitted[0], isA<EscapeKey>());
      expect(emitted[1], CharInput('q'));
    });

    test('Enter interrupting a reply is delivered, never eaten', () async {
      backend = makeBackend();
      // An OSC opener whose terminator never arrives, then the user hits
      // Enter: the swallow must abort on the control key.
      backend.pumpedBatchForTest(
        [nc.PumpedInput(0x1b, 0, 0), nc.PumpedInput(0x5d, 0, 0)],
      );
      await pumpMicrotasks();
      backend.pumpedInputForTest(0x0d);
      await pumpMicrotasks();
      expect(emitted, [ControlKey(ControlCode.enter)]);
    });

    test('explicit paste markers bypass the filter', () async {
      backend = makeBackend();
      backend.pumpedInputForTest(nc.NcKey.pasteBegin);
      backend.pumpedInputForTest(recId('a'));
      backend.pumpedInputForTest(0x1b);
      backend.pumpedInputForTest(recId(']'));
      backend.pumpedInputForTest(recId('b'));
      backend.pumpedInputForTest(nc.NcKey.pasteEnd);
      await pumpMicrotasks();
      expect(emitted, [PasteInput('a]b')],
          reason: 'marker-delimited content is known-genuine and unfiltered');
      // The filter must not be left holding the in-paste ESC: typing after
      // the paste still arrives.
      backend.pumpedInputForTest(recId('x'));
      await pumpMicrotasks();
      expect(emitted, [PasteInput('a]b'), CharInput('x')]);
    });

    test('replySequenceFiltering: false restores the unfiltered stream',
        () async {
      backend = makeBackend(replySequenceFiltering: false);
      backend.pumpedBatchForTest(bundleRecords());
      await pumpMicrotasks();
      expect(emitted, isNotEmpty,
          reason: 'without the filter the reply bytes reach the app (old bug)');
      expect(emitted.whereType<PasteInput>(), isEmpty);
      expect(
          emitted.whereType<CharInput>(), isNotEmpty,
          reason: 'the old failure mode was reply chars decoded as typing');
    });
  });

  // The notcurses twin of backtab_hook_test.dart. Over a TTY Shift+Tab is
  // ESC [ Z and the ANSI parser owns it; on this backend notcurses delivers
  // id='\t' with the shift modifier (ncinput_shift_p), which used to be
  // dropped at the FFI boundary — Shift+Tab landed as plain Tab and the #23
  // mode cycle was unreachable. Driven through pumpedInputForTest with
  // KeyMod.shift, no live terminal.
  group('backtab via notcurses pump', () {
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

    test('shift+tab (0x09 + shift) translates to backtab', () async {
      backend.pumpedInputForTest(0x09, modifiers: nc.KeyMod.shift);
      await pumpMicrotasks();
      expect(emitted, [ControlKey(ControlCode.backtab)],
          reason: 'shift must survive to translation; plain Tab is distinct');
    });

    test('plain tab stays tab', () async {
      backend.pumpedInputForTest(0x09);
      await pumpMicrotasks();
      expect(emitted, [ControlKey(ControlCode.tab)]);
    });
  });
}
