import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';

const _noTools = <ToolSchema>[];

/// Drain [stream] to its terminal event, returning the assembled events and any
/// error. Mirrors how `ProviderStreamConsumer` listens.
Future<({List<StreamEvent> events, Object? error})> _drain(
    Stream<StreamEvent> stream) async {
  final events = <StreamEvent>[];
  Object? error;
  final done = Completer<void>();
  final sub = stream.listen(
    (event) {
      // Mirror ProviderStreamConsumer: a StreamError is a normal in-band event
      // carrying an error, not a stream addError.
      if (event is StreamError) {
        error ??= event.error;
      } else {
        events.add(event);
      }
    },
    onError: (Object e) {
      error = e;
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future;
  await sub.cancel();
  return (events: events, error: error);
}

void main() {
  group('MeteringProvider', () {
    test('records MessageComplete.usage and passes events through', () async {
      final inner = FakeProvider([
        [
          const TextDelta('ok'),
          const MessageComplete(
            content: [TextBlock('ok')],
            stopReason: 'end_turn',
            usage: TokenUsage(inputTokens: 30, outputTokens: 70),
          ),
        ],
      ]);
      final ledger = SpendLedger(maxGlobalTokens: 1000, requestsPerMinute: 0);
      final provider = MeteringProvider(inner, ledger);

      final result = await _drain(provider.send(
        system: 's',
        messages: const [],
        tools: _noTools,
      ));

      expect(ledger.totalTokens, 100);
      expect(result.error, isNull);
      expect(result.events, hasLength(2));
      expect(result.events.first, isA<TextDelta>());
      expect(result.events.last, isA<MessageComplete>());
    });

    test('refuses to subscribe when the ledger is already tripped', () async {
      final inner = FakeProvider([
        [const MessageComplete(content: [], stopReason: 'end_turn')],
      ]);
      final ledger = SpendLedger(maxGlobalTokens: 10, requestsPerMinute: 0)
        ..record(const TokenUsage(inputTokens: 100, outputTokens: 100));
      expect(ledger.tripped, isTrue);

      final provider = MeteringProvider(inner, ledger);
      final result = await _drain(provider.send(
        system: 's',
        messages: const [],
        tools: _noTools,
      ));

      expect(inner.calls, isEmpty,
          reason: 'a tripped ledger must not hit the wire');
      expect(result.error, isA<SpendLimitExceeded>());
      expect(result.events, isEmpty);
    });

    test('forwards an inner StreamError unchanged', () async {
      final inner = FakeProvider([
        [const StreamError('upstream blew up')],
      ]);
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final provider = MeteringProvider(inner, ledger);

      final result = await _drain(provider.send(
        system: 's',
        messages: const [],
        tools: _noTools,
      ));

      expect(result.error, 'upstream blew up');
    });

    test('delegates model get/set to the inner provider', () {
      final inner = FakeProvider([], model: 'm1');
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final provider = MeteringProvider(inner, ledger);

      expect(provider.model, 'm1');
      provider.model = 'm2';
      expect(inner.model, 'm2', reason: '/model must reach the real provider');
    });

    test('cancel during the inner stream tears down the inner subscription',
        () async {
      var innerCancelled = false;
      final inner = HoldProvider(onCancel: () => innerCancelled = true);
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final provider = MeteringProvider(inner, ledger);

      final outer = provider
          .send(system: 's', messages: const [], tools: _noTools)
          .listen((_) {});
      await Future<void>.delayed(
          const Duration(milliseconds: 20)); // run() subscribes inner
      inner.controller.add(const TextDelta('partial'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await outer.cancel();

      expect(innerCancelled, isTrue,
          reason: 'ESC must cancel the underlying provider stream');
      await inner.controller.close();
    });

    test('cancel during an RPM wait returns within one tick (no hang)',
        () async {
      // rpm = 1: a natural slot grant would take ~60s; cancel must beat that.
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 1);
      await ledger.acquireRequestSlot(); // drain capacity
      final inner = FakeProvider([
        [const MessageComplete(content: [], stopReason: 'end_turn')],
      ]);
      final provider = MeteringProvider(inner, ledger);

      final sw = Stopwatch()..start();
      final sub = provider
          .send(system: 's', messages: const [], tools: _noTools)
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      // Let the background run() observe the cancel and return.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(300),
          reason: 'cancel during throttle must not hang');
      expect(inner.calls, isEmpty,
          reason: 'cancelled before a slot was granted → no wire traffic');
    });
  });
}
