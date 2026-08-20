import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';

const _ok = [
  TextDelta('served'),
  MessageComplete(
    content: [TextBlock('served')],
    stopReason: 'end_turn',
    usage: TokenUsage.zero,
  ),
];

Future<List<StreamEvent>> _drain(Stream<StreamEvent> s) => s.toList();

/// A member that counts [close] calls — [FakeProvider]'s close is the base
/// no-op, so pooling it proves nothing about fan-out.
class _ClosableProvider extends LlmProvider {
  final List<List<StreamEvent>> responses;
  int calls = 0;
  bool closed = false;

  _ClosableProvider(this.responses, {String model = 'member'})
      : super(model);

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    final i = calls++;
    if (i < responses.length) {
      for (final event in responses[i]) {
        yield event;
      }
    }
  }

  @override
  void close() => closed = true;
}

void main() {
  group('PooledProvider', () {
    test('strict round-robin across members over consecutive sends', () async {
      final a = _ClosableProvider([_ok, _ok]);
      final b = _ClosableProvider([_ok, _ok]);
      final c = _ClosableProvider([_ok, _ok]);
      final pool = PooledProvider([a, b, c]);

      for (var i = 0; i < 6; i++) {
        final events = await _drain(
            pool.send(system: 's', messages: const [], tools: const []));
        expect(events.whereType<StreamError>(), isEmpty,
            reason: 'send $i served cleanly');
      }

      expect(a.calls, 2, reason: 'member a served sends 0 and 3');
      expect(b.calls, 2, reason: 'member b served sends 1 and 4');
      expect(c.calls, 2, reason: 'member c served sends 2 and 5');
    });

    test('a before-content failure fails over; the member cools down', () async {
      final a = _ClosableProvider([
        [const StreamError('NIM 429: Too Many Requests', statusCode: 429)],
        _ok, // recovered — consumed once the cooldown elapses
      ]);
      final b = _ClosableProvider([_ok, _ok, _ok]);
      final c = _ClosableProvider([_ok, _ok, _ok]);
      final pool =
          PooledProvider([a, b, c], cooldown: const Duration(milliseconds: 40));

      // Send 1: a 429s before content — b serves the SAME send.
      final events1 = await _drain(
          pool.send(system: 's', messages: const [], tools: const []));
      expect(events1.whereType<StreamError>(), isEmpty,
          reason: 'the failed attempt is invisible — nothing duplicated');
      expect(events1.whereType<MessageComplete>(), isNotEmpty);
      expect(a.calls, 1);
      expect(b.calls, 1, reason: 'b picked up the failed send');

      // Send 2: rotation continues at c.
      await _drain(
          pool.send(system: 's', messages: const [], tools: const []));
      expect(c.calls, 1);

      // Send 3: rotation reaches a — still cooling, so b serves again.
      await _drain(
          pool.send(system: 's', messages: const [], tools: const []));
      expect(a.calls, 1, reason: 'a is skipped while cooling');
      expect(b.calls, 2);

      // Cooldown elapses; the rotation reaches a again and it serves.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _drain(
          pool.send(system: 's', messages: const [], tools: const []));
      expect(c.calls, 2);
      await _drain(
          pool.send(system: 's', messages: const [], tools: const []));
      expect(a.calls, 2, reason: 'a serves again once its cooldown lapses');
    });

    test('an empty completion fails over to the next member', () async {
      // The exhausted-worker shape: 200, zero content blocks. The send must
      // not complete empty-handed — the member cools down and the next one
      // serves the SAME send.
      final a = _ClosableProvider([
        [const MessageComplete(content: [], stopReason: 'end_turn')],
      ]);
      final b = _ClosableProvider([_ok]);
      final pool = PooledProvider([a, b]);

      final events = await _drain(
          pool.send(system: 's', messages: const [], tools: const []));

      expect(b.calls, 1, reason: 'the empty member is failed over from');
      final complete = events.whereType<MessageComplete>().single;
      expect(complete.content, isNotEmpty);
      expect(events.whereType<StreamError>(), isEmpty,
          reason: 'the failover is invisible downstream');
    });

    test('every member returning an empty completion surfaces an error', () async {
      final a = _ClosableProvider([
        [const MessageComplete(content: [], stopReason: 'end_turn')],
      ]);
      final b = _ClosableProvider([
        [const MessageComplete(content: [], stopReason: 'end_turn')],
      ]);
      final pool = PooledProvider([a, b]);

      final events = await _drain(
          pool.send(system: 's', messages: const [], tools: const []));

      expect(a.calls, 1);
      expect(b.calls, 1);
      final error = events.whereType<StreamError>().single;
      expect(error.error.toString(), contains('empty completion'));
      expect(error.transient, isTrue,
          reason: 'the policy retry layer may re-attempt it');
    });

    test('a failure after content started surfaces — no failover', () async {
      final a = _ClosableProvider([
        [const TextDelta('partial'), const StreamError('cut off', statusCode: 429)],
      ]);
      final b = _ClosableProvider([_ok]);
      final pool = PooledProvider([a, b]);

      final events = await _drain(
          pool.send(system: 's', messages: const [], tools: const []));

      expect(b.calls, 0,
          reason: 'no member is touched — failing over would duplicate the partial content');
      expect(events.whereType<TextDelta>().single.text, 'partial');
      expect(events.whereType<StreamError>().single.statusCode, 429);
    });

    test('every member failing before content surfaces the last error',
        () async {
      final a = _ClosableProvider([
        [const StreamError('a down', statusCode: 500)],
      ]);
      final b = _ClosableProvider([
        [const StreamError('b down', statusCode: 500)],
      ]);
      final c = _ClosableProvider([
        [const StreamError('c down', statusCode: 429)],
      ]);
      final pool = PooledProvider([a, b, c]);

      final events = await _drain(
          pool.send(system: 's', messages: const [], tools: const []));

      expect(a.calls, 1);
      expect(b.calls, 1);
      expect(c.calls, 1, reason: 'one full pass over the pool');
      final error = events.whereType<StreamError>().single;
      expect(error.statusCode, 429,
          reason: 'the LAST member\'s error is the one surfaced');
    });

    test('a send while every member is cooling paces until one recovers',
        () async {
      final a = _ClosableProvider([
        [const StreamError('down', statusCode: 503)],
        _ok,
      ]);
      final pool =
          PooledProvider([a], cooldown: const Duration(milliseconds: 60));

      final first = await _drain(
          pool.send(system: 's', messages: const [], tools: const []));
      expect(first.whereType<StreamError>().single.statusCode, 503);

      // The single member is now cooling for 60ms. An immediate re-send
      // must not hammer it NOR error — it paces until the cooldown lapses,
      // then the member serves. (Erroring here aborted real runs: the
      // policy retry's backoff is shorter than the cooldown, so every
      // re-entry found the same wall.)
      final second = await _drain(
          pool.send(system: 's', messages: const [], tools: const []));
      expect(a.calls, 2, reason: 'the send waited out the cooldown');
      expect(second.whereType<MessageComplete>(), isNotEmpty,
          reason: 'the paced send completes, not errors');
      expect(second.whereType<StreamError>(), isEmpty);
    });

    test('a downstream cancel tears down the inner member subscription',
        () async {
      var innerCancelled = false;
      final hold = HoldProvider(
        gate: Completer<void>().future,
        onCancel: () => innerCancelled = true,
      );
      final pool = PooledProvider([hold]);

      final sub = pool
          .send(system: 's', messages: const [], tools: const [])
          .listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(innerCancelled, true,
          reason: 'cancelling the pool stream cancels the member stream');
    });

    test('close() closes every member', () {
      final a = _ClosableProvider([_ok]);
      final b = _ClosableProvider([_ok]);
      final pool = PooledProvider([a, b]);

      pool.close();

      expect(a.closed, isTrue);
      expect(b.closed, isTrue);
    });

    test('a model swap reaches every member (the pool stays equivalent)',
        () {
      final a = _ClosableProvider([_ok], model: 'm1');
      final b = _ClosableProvider([_ok], model: 'm1');
      final pool = PooledProvider([a, b]);

      expect(pool.model, 'm1', reason: 'identity comes from the first member');
      pool.model = 'm2';

      expect(a.model, 'm2');
      expect(b.model, 'm2');
    });
  });
}
