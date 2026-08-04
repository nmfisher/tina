import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('PauseGate.requestPause', () {
    test('closes the gate and emits the reason once', () async {
      final gate = PauseGate();
      final events = <String>[];
      final sub = gate.onPause.listen(events.add);

      gate.requestPause('over budget');
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(gate.isPaused, isTrue);
      expect(gate.reason, 'over budget');
      expect(events, ['over budget']);
      await sub.cancel();
      await gate.dispose();
    });

    test('is idempotent: a second requestPause does not re-emit', () async {
      final gate = PauseGate();
      final events = <String>[];
      final sub = gate.onPause.listen(events.add);

      gate.requestPause('first');
      gate.requestPause('second');
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(events, ['first'], reason: 'only the first trip emits');
      expect(gate.reason, 'first', reason: 'first tripper wins');
      await sub.cancel();
      await gate.dispose();
    });
  });

  group('PauseGate.waitForResume', () {
    test('returns true immediately when not paused', () async {
      final gate = PauseGate();
      final sw = Stopwatch()..start();
      final ok = await gate.waitForResume();
      sw.stop();
      expect(ok, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(50));
      await gate.dispose();
    });

    test('blocks while paused; resume(true) resolves all waiters with true',
        () async {
      final gate = PauseGate()..requestPause('over');
      final a = gate.waitForResume();
      final b = gate.waitForResume();
      expect(gate.isPaused, isTrue);

      gate.resume(continueDecision: true);
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(gate.isPaused, isFalse);
      await gate.dispose();
    });

    test('resume(false) resolves waiters with false (abort)', () async {
      final gate = PauseGate()..requestPause('over');
      final a = gate.waitForResume();
      gate.resume(continueDecision: false);
      expect(await a, isFalse);
      await gate.dispose();
    });

    test('cancelSignal returns false promptly and removes the waiter', () async {
      final gate = PauseGate()..requestPause('over');
      final cancelSignal = Completer<void>()..complete();
      final sw = Stopwatch()..start();
      final ok = await gate.waitForResume(cancelSignal: cancelSignal.future);
      sw.stop();

      expect(ok, isFalse, reason: 'cancel must abort the wait');
      expect(sw.elapsedMilliseconds, lessThan(50));
      expect(gate.isPaused, isTrue, reason: 'cancel does not open the gate');

      // The cancelled waiter was removed, so a later resume completes nothing
      // extra (and does not throw on the already-completed completer).
      gate.resume(continueDecision: true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await gate.dispose();
    });
  });
}
