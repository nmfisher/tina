import 'dart:async';

import 'package:tina/host/headless_watchdog.dart';
import 'package:test/test.dart';

/// Injected clock: tests step time forward by hand — no real sleeps.
class _Clock {
  DateTime _now = DateTime(2026, 1, 1);
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

/// Let already-scheduled zero-duration timers run. Same-expiry timers fire
/// in creation order, so pumping after [HeadlessWatchdog.start] with a
/// zero timeout lets its timer callback run without sleeping.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('HeadlessWatchdog', () {
    test('fires exactly once when the timeout expires, with the diagnostic',
        () async {
      final fired = <String>[];
      final w = HeadlessWatchdog(
        timeout: Duration.zero,
        onFire: fired.add,
      );
      w.start();
      await _pump();
      await _pump();
      expect(fired, hasLength(1));
      expect(fired.single, startsWith('[watchdog] no agent activity for 0s'));
      expect(fired.single, contains('last event: none'));
      expect(fired.single, contains('never resolves'));
      // Fire-once: later pumps (or records) never fire it again.
      w.record('ToolAgentEvent');
      await _pump();
      await _pump();
      expect(fired, hasLength(1));
      expect(w.fired, isTrue);
    });

    test('record() resets the idle clock so checkIdle does not expire', () {
      final clock = _Clock();
      final w = HeadlessWatchdog(
        timeout: const Duration(seconds: 300),
        onFire: (_) => throw StateError('must not fire'),
        nowProvider: clock.now,
      );
      clock.advance(const Duration(seconds: 290));
      w.record('ToolAgentEvent');
      expect(w.lastEventName, 'ToolAgentEvent');
      expect(w.eventCount, 1);
      // 300s since the epoch start, but only 10s since the event: no fire.
      clock.advance(const Duration(seconds: 10));
      expect(w.checkIdle(clock.now()), isFalse);
      // …until a full timeout passes with no further event.
      clock.advance(const Duration(seconds: 290));
      expect(w.checkIdle(clock.now()), isTrue);
      w.dispose();
    });

    test('the diagnostic names the last event, its age, and the event count',
        () async {
      final fired = <String>[];
      final w = HeadlessWatchdog(
        timeout: Duration.zero,
        onFire: fired.add,
      );
      w.record('AssistantAgentEvent');
      w.record('ToolAgentEvent');
      await _pump();
      expect(fired, hasLength(1));
      expect(fired.single, contains('last event: ToolAgentEvent'));
      expect(fired.single, contains('total events: 2'));
      expect(fired.single, contains('at +0s'));
    });

    test('dispose() cancels a pending timer', () async {
      final fired = <String>[];
      final w = HeadlessWatchdog(
        timeout: Duration.zero,
        onFire: fired.add,
      );
      w.start();
      w.dispose();
      await _pump();
      await _pump();
      expect(fired, isEmpty);
    });

    test('checkIdle is false before any event has been recorded', () {
      final clock = _Clock();
      final w = HeadlessWatchdog(
        timeout: const Duration(seconds: 5),
        onFire: (_) => throw StateError('must not fire'),
        nowProvider: clock.now,
      );
      clock.advance(const Duration(seconds: 999));
      expect(w.checkIdle(clock.now()), isFalse);
    });
  });
}
