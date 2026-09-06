import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine/src/timers/timer_service.dart';

/// Deterministic timer tests (spec §11): fake factory + fake clock, no sleeps.
const int epochMs = 1730000000000;

DateTime clockNow = DateTime.fromMillisecondsSinceEpoch(epochMs);

class FakeTimer implements Timer {
  final Duration initialDelay;
  void Function()? callback;
  bool cancelled = false;

  FakeTimer(this.initialDelay);

  @override
  int get tick => initialDelay.inMilliseconds;

  @override
  bool get isActive => !cancelled && callback != null;

  @override
  void cancel() {
    cancelled = true;
    callback = null;
  }

  /// Simulates the event loop: moves the fake clock to fire time, runs the
  /// one-shot callback.
  void fire() {
    if (!isActive) throw StateError('timer not active');
    clockNow = clockNow.add(initialDelay);
    final cb = callback;
    callback = null;
    cb!();
  }
}

class FakeFactory {
  final List<FakeTimer> timers = [];

  Timer call(Duration duration, void Function() callback) {
    final t = FakeTimer(duration);
    t.callback = callback;
    timers.add(t);
    return t;
  }

  FakeTimer get last => timers.last;
}

class Harness {
  late TimerService service;
  final FakeFactory factory = FakeFactory();
  final List<String> fires = [];
  final List<String> notices = [];
  final List<String> warnings = [];
  String? sessionId;

  Harness() {
    service = TimerService(
      onFire: (name, n) => fires.add('$name#$n'),
      onNotice: (text, {required bool warning}) =>
          warning ? warnings.add(text) : notices.add(text),
      timerFactory: factory.call,
      clock: () => clockNow,
      currentSessionId: () => sessionId,
    );
  }

  FakeTimer get lastTimer => factory.last;
}

TimerSpec spec(
  String name, {
  Duration every = const Duration(minutes: 5),
  String instruction = 'check it',
  bool once = false,
  int? maxFires,
}) =>
    TimerSpec(
      name: name,
      interval: every,
      instruction: instruction,
      once: once,
      maxFires: maxFires,
    );

void main() {
  setUp(() {
    clockNow = DateTime.fromMillisecondsSinceEpoch(epochMs);
  });

  group('set', () {
    test('create returns created and arms one timer', () {
      final h = Harness();
      expect(h.service.set(spec('a')), isA<TimerSetCreated>());
      expect(h.factory.timers, hasLength(1));
      expect(h.service.list().single.name, 'a');
    });

    test('grid anchor is now + interval (§4.4 step 1)', () {
      final h = Harness();
      h.service.set(spec('a'));
      expect(h.service.list().single.nextFireAt,
          clockNow.add(const Duration(minutes: 5)));
    });

    test('replace: fresh counters, suspension cleared, new interval', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.lastTimer.fire();
      h.service.ackStarted('a');
      h.service.ackFinished('a', aborted: true);
      final outcome =
          h.service.set(spec('a', every: const Duration(minutes: 7)));
      expect(outcome, isA<TimerSetReplaced>());
      final s = h.service.list().single;
      expect(s.fireCount, 0);
      expect(s.consecutiveAbortedFires, 0);
      expect(s.suspended, isFalse);
      expect(s.interval, const Duration(minutes: 7));
    });

    test('replace does not double-count against the cap (§4.4 step 6)', () {
      final h = Harness();
      for (var i = 0; i < kMaxActiveTimers; i++) {
        expect(h.service.set(spec('t$i')), isA<TimerSetCreated>());
      }
      expect(h.service.set(spec('t0')), isA<TimerSetReplaced>());
      expect(h.service.set(spec('t8')), isA<TimerSetRejected>());
    });

    test('cap rejection reason matches §6.1 wording', () {
      final h = Harness();
      for (var i = 0; i < kMaxActiveTimers; i++) {
        h.service.set(spec('t$i'));
      }
      final outcome = h.service.set(spec('extra'));
      expect((outcome as TimerSetRejected).reason, '8-timer limit reached');
    });

    test('entries are tagged with the session id captured at set time', () {
      final h = Harness();
      h.sessionId = 's1';
      h.service.set(spec('a'));
      h.sessionId = 's2';
      h.service.set(spec('b'));
      final exported = h.service.exportState();
      expect(exported[0]['sessionId'], 's1');
      expect(exported[1]['sessionId'], 's2');
    });
  });

  group('cancel/list', () {
    test('cancel returns false on unknown name', () {
      final h = Harness();
      expect(h.service.cancel('nope'), isFalse);
    });

    test('cancel disarms and removes', () {
      final h = Harness();
      h.service.set(spec('a'));
      final t = h.lastTimer;
      expect(h.service.cancel('a'), isTrue);
      expect(t.isActive, isFalse);
      expect(h.service.list(), isEmpty);
    });

    test('list includes suspended entries (§4.4 step 7)', () {
      final h = Harness();
      h.service.set(spec('a'));
      for (var i = 0; i < kMaxTimerFiresBeforeSuspend; i++) {
        h.lastTimer.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: true);
      }
      expect(h.service.list(), hasLength(1));
      expect(h.service.list().single.suspended, isTrue);
    });
  });

  group('fire cycle', () {
    test('arm -> tick -> onFire(name, 1), state queued', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.lastTimer.fire();
      expect(h.fires, ['a#1']);
      expect(h.service.list().single.state, TimerEntryState.queued);
    });

    test('second tick while queued collapses; ONE notice per window', () {
      final h = Harness();
      h.service.set(spec('a', every: const Duration(seconds: 30)));
      h.lastTimer.fire(); // fire #1 -> queued
      h.lastTimer.fire(); // collapse #1: notice
      expect(h.fires, ['a#1']);
      expect(h.notices, hasLength(1));
      h.lastTimer.fire(); // collapse #2: no second notice
      expect(h.fires, ['a#1']);
      expect(h.notices, hasLength(1));
      h.service.ackFinished('a', aborted: false); // window closes
      h.lastTimer.fire(); // new window: fires, notice flag reset
      expect(h.fires, ['a#1', 'a#2']);
      expect(h.notices, hasLength(1));
    });

    test('collapse notice re-arms for another later collapse', () {
      final h = Harness();
      h.service.set(spec('a', every: const Duration(seconds: 30)));
      h.lastTimer.fire();
      h.lastTimer.fire(); // notice 1
      h.service.ackFinished('a', aborted: false);
      h.lastTimer.fire(); // fire #2
      h.lastTimer.fire(); // notice 2 (new window)
      expect(h.fires, ['a#1', 'a#2']);
      expect(h.notices, hasLength(2));
    });

    test('queued -> running -> idle via acks', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.lastTimer.fire();
      h.service.ackStarted('a');
      expect(h.service.list().single.state, TimerEntryState.running);
      h.service.ackFinished('a', aborted: false);
      expect(h.service.list().single.state, TimerEntryState.idle);
    });

    test('acks tolerated no-ops in wrong states (§4.4 step 4)', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.service.ackStarted('a'); // idle: no-op
      expect(h.service.list().single.state, TimerEntryState.idle);
      h.service.ackFinished('a', aborted: true); // idle: no-op
      expect(h.fires, isEmpty);
      h.lastTimer.fire();
      h.service.ackStarted('a');
      h.service.ackStarted('a'); // running: no-op
      expect(h.service.list().single.state, TimerEntryState.running);
    });

    test('grid anchor never drifts: next anchor = old anchor + interval', () {
      final h = Harness();
      h.service.set(spec('a'));
      final anchor1 = clockNow.add(const Duration(minutes: 5));
      h.lastTimer.fire(); // fires exactly at anchor1; anchor -> anchor2
      clockNow = clockNow.add(const Duration(minutes: 5, seconds: 20));
      h.service.ackFinished('a', aborted: false);
      // anchor2 = anchor1 + 5m = T0+10m fell in the past during the check,
      // so the re-arm landed on anchor2 + 5m = T0+15m (not now + 5m).
      expect(h.service.list().single.nextFireAt,
          anchor1.add(const Duration(minutes: 10)));
    });

    test('past-tick skip: long check lands next fire on the grid', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.lastTimer.fire(); // fire #1 at T0+5m
      clockNow = clockNow.add(const Duration(minutes: 12)); // check ran 12m
      h.service.ackFinished('a', aborted: false);
      // Grid points T0+10m (past) skipped; next is T0+15m -> 3m from now.
      expect(h.service.list().single.nextFireAt,
          clockNow.add(const Duration(minutes: 3)));
      h.lastTimer.fire();
      expect(h.fires, ['a#1', 'a#2']);
    });

    test('zero-delay arm is safe: immediate tick collapses when busy', () {
      final h = Harness();
      h.service.set(spec('a', every: const Duration(seconds: 30)));
      h.lastTimer.fire(); // queued
      h.service.ackFinished('a', aborted: false);
      // ackFinished re-armed at the anchor in the past -> delay 0.
      h.lastTimer.fire(); // fresh fire (window closed) — fine.
      expect(h.fires, ['a#1', 'a#2']);
    });

    test('once removes the entry after its single fire', () {
      final h = Harness();
      h.service.set(spec('a', once: true));
      h.lastTimer.fire();
      h.service.ackStarted('a');
      h.service.ackFinished('a', aborted: false);
      expect(h.service.list(), isEmpty);
    });

    test('maxFires removes the entry when used up', () {
      final h = Harness();
      h.service.set(spec('a', maxFires: 2));
      for (var i = 0; i < 2; i++) {
        h.lastTimer.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: false);
      }
      expect(h.service.list(), isEmpty);
      expect(h.fires, ['a#1', 'a#2']);
    });

    test('abort increments the streak; clean fire resets it', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.lastTimer.fire();
      h.service.ackStarted('a');
      h.service.ackFinished('a', aborted: true);
      expect(h.service.list().single.consecutiveAbortedFires, 1);
      h.lastTimer.fire();
      h.service.ackStarted('a');
      h.service.ackFinished('a', aborted: false);
      expect(h.service.list().single.consecutiveAbortedFires, 0);
    });

    test('collapsed ticks do not consume maxFires slots', () {
      final h = Harness();
      h.service.set(spec('a', maxFires: 1));
      h.lastTimer.fire();
      h.lastTimer.fire(); // collapse
      expect(h.service.list().single.fireCount, 1);
    });
  });

  group('runaway guard (§8)', () {
    test('suspends at 6 consecutive aborted fires and emits the notice', () {
      final h = Harness();
      h.service.set(spec('a'));
      for (var i = 0; i < kMaxTimerFiresBeforeSuspend; i++) {
        h.lastTimer.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: true);
      }
      expect(h.service.list().single.suspended, isTrue);
      expect(h.warnings, hasLength(1));
      expect(
        h.warnings.single,
        '[timer a suspended after 6 consecutive failed checks — /timers '
        'cancel a, or ask the agent to fix and re-set it]',
      );
    });

    test('suspension disarms the timer and holds the cap slot', () {
      final h = Harness();
      h.service.set(spec('a'));
      for (var i = 0; i < kMaxTimerFiresBeforeSuspend; i++) {
        h.lastTimer.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: true);
      }
      expect(h.lastTimer.isActive, isFalse);
      expect(h.service.list(), hasLength(1));
    });

    test('five aborts do not suspend; suspend fires exactly once', () {
      final h = Harness();
      h.service.set(spec('a'));
      for (var i = 0; i < kMaxTimerFiresBeforeSuspend - 1; i++) {
        h.lastTimer.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: true);
      }
      expect(h.service.list().single.suspended, isFalse);
      expect(h.warnings, isEmpty);
    });

    test('replacement is the documented path back from suspension', () {
      final h = Harness();
      h.service.set(spec('a'));
      for (var i = 0; i < kMaxTimerFiresBeforeSuspend; i++) {
        h.lastTimer.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: true);
      }
      expect(h.service.set(spec('a')), isA<TimerSetReplaced>());
      final s = h.service.list().single;
      expect(s.suspended, isFalse);
      expect(s.consecutiveAbortedFires, 0);
      expect(h.lastTimer.isActive, isTrue);
    });

    test('an aborted fire past suspension is a tolerated no-op', () {
      final h = Harness();
      h.service.set(spec('a'));
      for (var i = 0; i < kMaxTimerFiresBeforeSuspend; i++) {
        h.lastTimer.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: true);
      }
      h.service.ackStarted('a'); // suspended, idle: no-op
      h.service.ackFinished('a', aborted: true); // idle: no-op
      expect(h.warnings, hasLength(1));
      expect(h.service.list().single.consecutiveAbortedFires,
          kMaxTimerFiresBeforeSuspend);
    });
  });

  group('exportState/restoreState', () {
    test('export: the §10 fields with counters and anchor verbatim', () {
      final h = Harness();
      h.service.set(spec('a', maxFires: 4));
      h.lastTimer.fire(); // fireCount 1, queued
      // The fire tick advanced the anchor from T0+5m to T0+10m (§4.4 step 3).
      expect(h.service.exportState().single, {
        'name': 'a',
        'everyMs': 300000,
        'instruction': 'check it',
        'once': false,
        'maxFires': 4,
        'fireCount': 1,
        'consecutiveAbortedFires': 0,
        'suspended': false,
        'anchorEpochMs': epochMs + 600000,
        'sessionId': null,
      });
    });

    test('export carries no state field: queued/running save as idle', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.lastTimer.fire(); // queued
      h.service.ackStarted('a'); // running
      final exported = h.service.exportState();
      expect(exported.single.containsKey('state'), isFalse);
      final h2 = Harness();
      h2.service.restoreState(exported);
      expect(h2.service.list().single.state, TimerEntryState.idle);
    });

    test('restore preserves counters and anchor verbatim and re-arms', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.lastTimer.fire(); // fireCount 1; the tick advanced the anchor
      final exported = h.service.exportState();
      final h2 = Harness();
      expect(h2.service.restoreState(exported), isEmpty);
      final s = h2.service.list().single;
      expect(s.fireCount, 1);
      expect(s.interval, const Duration(minutes: 5));
      // Anchor as saved (T0+10m — the tick had advanced it); the restore
      // arms verbatim, so the first fire is 10m out, not 5m.
      expect(s.nextFireAt,
          DateTime.fromMillisecondsSinceEpoch(epochMs + 600000));
      expect(h2.lastTimer.isActive, isTrue);
    });

    test('suspended entries restore AS suspended and stay disarmed (§10)', () {
      final h = Harness();
      h.service.set(spec('a'));
      for (var i = 0; i < kMaxTimerFiresBeforeSuspend; i++) {
        h.lastTimer.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: true);
      }
      final exported = h.service.exportState();
      final h2 = Harness();
      expect(h2.service.restoreState(exported), isEmpty);
      final s = h2.service.list().single;
      expect(s.suspended, isTrue);
      expect(h2.factory.timers, isEmpty, reason: 'no timer armed');
    });

    test('restore respects the cap, returning names that did not fit', () {
      final h2 = Harness();
      final saved = <Map<String, Object?>>[];
      for (var i = 0; i < kMaxActiveTimers + 2; i++) {
        h2.service.set(spec('r$i'));
        saved.addAll(h2.service.exportState());
        h2.service.cancel('r$i');
      }
      // `saved` holds 10 records; the service is empty again.
      final notRestored = h2.service.restoreState(saved);
      expect(h2.service.list(), hasLength(kMaxActiveTimers));
      expect(notRestored, ['r8', 'r9']);
    });

    test('restore skips malformed records silently', () {
      final h = Harness();
      final notRestored = h.service.restoreState([
        {'name': 'x'}, // missing everything else
        {'name': 3, 'everyMs': 1000, 'instruction': 'i', 'once': false,
          'maxFires': null, 'fireCount': 0, 'consecutiveAbortedFires': 0,
          'suspended': false, 'anchorEpochMs': epochMs},
      ]);
      expect(notRestored, isEmpty);
      expect(h.service.list(), isEmpty);
    });
  });

  group('dispose', () {
    test('dispose cancels every armed timer; entries stay listed', () {
      final h = Harness();
      h.service.set(spec('a'));
      h.service.set(spec('b'));
      final tA = h.factory.timers[0];
      final tB = h.factory.timers[1];
      h.service.dispose();
      expect(tA.isActive, isFalse);
      expect(tB.isActive, isFalse);
      expect(h.service.list(), hasLength(2));
    });
  });
}
