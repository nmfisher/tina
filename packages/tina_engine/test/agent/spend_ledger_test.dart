import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

TokenUsage _u(int inOut, {int cache = 0}) => TokenUsage(
      inputTokens: inOut,
      outputTokens: inOut,
      cacheCreationInputTokens: cache,
      cacheReadInputTokens: cache,
    );

void main() {
  test('raising/removing global cap preserves spend and releases its trip', () {
    final ledger = SpendLedger(maxGlobalTokens: 50, requestsPerMinute: 0);
    ledger.record(const TokenUsage(inputTokens: 40, outputTokens: 20));
    ledger.recordEstimated(const TokenUsage(inputTokens: 10, outputTokens: 0));
    expect(ledger.tripped, isTrue);
    ledger.updateLimits(maxGlobalTokens: 100, requestsPerMinute: 0);
    expect(ledger.tripped, isFalse);
    expect(ledger.reason, isNull);
    expect(ledger.totalTokens, 60);
    expect(ledger.totalEstimatedTokens, 10);
    ledger.updateLimits(maxGlobalTokens: 30, requestsPerMinute: 0);
    expect(ledger.tripped, isTrue);
    ledger.updateLimits(maxGlobalTokens: 0, requestsPerMinute: 0);
    expect(ledger.tripped, isFalse);
    expect(ledger.grandTotalTokens, 70);
  });

  test('disabling RPM releases an already waiting request', () async {
    final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 1);
    expect(await ledger.acquireRequestSlot(), isTrue);
    final pending = ledger.acquireRequestSlot();
    ledger.updateLimits(maxGlobalTokens: 0, requestsPerMinute: 0);
    expect(await pending.timeout(const Duration(seconds: 1)), isTrue);
  });


  group('SpendLedger.record / ceiling', () {
    test('accumulates input+output and does not trip under the cap', () {
      final l = SpendLedger(maxGlobalTokens: 1000, requestsPerMinute: 0);
      l.record(_u(100));
      l.record(_u(200));
      expect(l.totalTokens, 600); // 100+100 + 200+200
      expect(l.tripped, isFalse);
      expect(l.reason, isNull);
    });

    test('excludes cache tokens (matches TokenBudget accounting)', () {
      final l = SpendLedger(maxGlobalTokens: 1000, requestsPerMinute: 0);
      l.record(_u(100, cache: 9999));
      expect(l.totalTokens, 200); // cache tokens ignored
    });

    test('trips exactly once when crossing the cap; reason is stable', () {
      final l = SpendLedger(maxGlobalTokens: 500, requestsPerMinute: 0);
      l.record(_u(200)); // 400, under
      expect(l.tripped, isFalse);
      l.record(_u(200)); // 800, over → trip
      expect(l.tripped, isTrue);
      final reason = l.reason;
      expect(reason, contains('global token spend ceiling exceeded'));
      expect(reason, contains('800 > 500'));
      l.record(_u(1)); // keep counting, don't rewrite reason
      expect(l.totalTokens, 802);
      expect(l.reason, same(reason));
    });

    test('maxGlobalTokens 0 is unbounded (never trips)', () {
      final l = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      l.record(_u(1000000));
      expect(l.tripped, isFalse);
      expect(l.cap, isNull);
    });

    test('reset zeros totals and clears the trip', () {
      final l = SpendLedger(maxGlobalTokens: 10, requestsPerMinute: 0);
      l.record(_u(100));
      expect(l.tripped, isTrue);
      l.reset();
      expect(l.totalTokens, 0);
      expect(l.tripped, isFalse);
      expect(l.reason, isNull);
    });
  });

  group('SpendLedger.acquireRequestSlot (RPM)', () {
    test('disabled (rpm 0) completes immediately', () async {
      final l = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final sw = Stopwatch()..start();
      final granted = await l.acquireRequestSlot();
      sw.stop();
      expect(granted, isTrue);
      expect(sw.elapsedMilliseconds, lessThan(50),
          reason: 'disabled throttle must not wait');
    });

    test('grants immediately while the bucket has capacity', () async {
      final l = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 60);
      expect(await l.acquireRequestSlot(), isTrue);
    });

    test('refills by elapsed time (deterministic, fake clock)', () async {
      var t = DateTime(2026, 7, 1, 12);
      final l = SpendLedger(
        maxGlobalTokens: 0,
        requestsPerMinute: 60, // 1 token / second
        now: () => t,
      );
      // Drain the bucket (capacity 60).
      for (var i = 0; i < 60; i++) {
        expect(await l.acquireRequestSlot(), isTrue);
      }
      // Bucket empty; advance the clock 2 seconds → 2 tokens refill.
      t = t.add(const Duration(seconds: 2));
      expect(await l.acquireRequestSlot(), isTrue); // immediate, no wait
      expect(await l.acquireRequestSlot(), isTrue);
    });

    test('waits for a refill when drained (real clock)', () async {
      final l = SpendLedger(maxGlobalTokens: 0,
          requestsPerMinute: 600); // 10 tokens/sec
      for (var i = 0; i < 600; i++) {
        await l.acquireRequestSlot();
      }
      final sw = Stopwatch()..start();
      final granted = await l.acquireRequestSlot();
      sw.stop();
      expect(granted, isTrue);
      expect(sw.elapsedMilliseconds, greaterThan(20),
          reason: 'a drained bucket must wait for a refill');
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('cancel returns false promptly without a token (real clock)', () async {
      // Very low RPM so a natural grant would take ~60s; cancel must return in
      // well under that, proving the wait is cancel-bound, not refill-bound.
      final l = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 1);
      await l.acquireRequestSlot(); // drain the single-token capacity
      final sw = Stopwatch()..start();
      final cancelSignal = Completer<void>()..complete();
      final granted = await l.acquireRequestSlot(cancelSignal: cancelSignal.future);
      sw.stop();
      expect(granted, isFalse, reason: 'cancel must abort without consuming');
      expect(sw.elapsedMilliseconds, lessThan(300));
    });
  });

  group('SpendLedger.seed / merge (restore + fleet)', () {
    test('seed restores the total, tracks seededTokens, never trips', () {
      final l = SpendLedger(maxGlobalTokens: 1000, requestsPerMinute: 0);
      // Restored usage may exceed this process's cap — history doesn't trip.
      l.seed(5000);
      expect(l.totalTokens, 5000);
      expect(l.seededTokens, 5000);
      expect(l.tripped, isFalse);

      // Live spend after restore counts from the restored base and can trip.
      l.record(_u(10));
      expect(l.totalTokens, 5020);
      expect(l.seededTokens, 5000);
      expect(l.tripped, isTrue);
    });

    test('merge folds another ledger in and trips when over the cap', () {
      final live = SpendLedger(maxGlobalTokens: 1000, requestsPerMinute: 0);
      final fleet = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      fleet.record(_u(400));
      live.merge(fleet);
      expect(live.totalTokens, 800);
      expect(live.seededTokens, 0);

      fleet.record(_u(200)); // fleet total: 800 + 400 = 1200
      live.merge(fleet);
      expect(live.totalTokens, 2000);
      expect(live.tripped, isTrue);
      expect(live.reason, contains('ceiling exceeded'));
    });

    test('merge of an empty ledger is a no-op', () {
      final live = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      live.record(_u(10));
      final empty = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      live.merge(empty);
      expect(live.totalTokens, 20);
    });

    test('reset clears the seeded portion too', () {
      final l = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      l.seed(900);
      l.reset();
      expect(l.totalTokens, 0);
      expect(l.seededTokens, 0);
    });
  });

  group('changes stream (live status display)', () {
    // Broadcast delivery is a microtask late; pump between mutation and read.
    Future<void> pump() => Future<void>.delayed(Duration.zero);

    test('record, seed, merge, updateLimits, reset each notify once', () async {
      final l = SpendLedger(maxGlobalTokens: 1000, requestsPerMinute: 0);
      var events = 0;
      final sub = l.changes.listen((_) => events++);
      l.record(_u(10));
      await pump();
      expect(events, 1);
      l.recordEstimated(_u(5));
      await pump();
      expect(events, 2);
      l.recordRetried(_u(3), estimated: true);
      await pump();
      // recordRetried fans out into recordEstimated (one notify), not two.
      expect(events, 3);
      l.seed(100);
      await pump();
      expect(events, 4);
      l.updateLimits(maxGlobalTokens: 2000, requestsPerMinute: 0);
      await pump();
      expect(events, 5);
      l.reset();
      await pump();
      expect(events, 6);
      // merge of an empty ledger stays silent (no-op fast path).
      final empty = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      l.merge(empty);
      await pump();
      expect(events, 6);
      // Merge with real totals notifies.
      final fleet = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      fleet.record(_u(7));
      l.merge(fleet);
      await pump();
      expect(events, 7);
      await sub.cancel();
    });

    test('an estimated usage routed through record still notifies once', () async {
      final l = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      var events = 0;
      final sub = l.changes.listen((_) => events++);
      l.record(const TokenUsage(
        inputTokens: 4,
        outputTokens: 0,
        estimated: true,
      ));
      await pump();
      expect(events, 1);
      expect(l.totalEstimatedTokens, 4);
      await sub.cancel();
    });

    test('close ends the stream without disturbing live listeners', () async {
      final l = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      var done = false;
      final sub = l.changes.listen(null, onDone: () => done = true);
      await l.close();
      expect(done, isTrue);
      await sub.cancel();
    });
  });
}
