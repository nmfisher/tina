import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

void main() {
  test('settlement follows synchronous publication and outcome callbacks',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('done')]), plugins: []);
    final persisted = <int>[];
    loop.subscribeBatches(
        (entries, _) => persisted.addAll(entries.map((e) => e.seq)));
    var callbackFinished = false;
    final settled = <InputSettlement>[];
    final sub = loop.inputSettlements.listen((event) {
      expect(callbackFinished, isTrue);
      expect(persisted.last, loop.publishedSeq);
      settled.add(event);
    });
    addTearDown(sub.cancel);
    await loop.runTurn(const Input('hello', id: 'input'),
        onOutcome: (_) => callbackFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(settled.single.inputId, 'input');
    expect(settled.single.stopReason, StopReason.complete);
    expect(settled.single.started, isTrue);
  });

  test(
      'outcome callback failure reports failure and preserves error propagation',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('done')]), plugins: []);
    final settled = <InputSettlement>[];
    final sub = loop.inputSettlements.listen(settled.add);
    addTearDown(sub.cancel);
    final failure = StateError('callback failed');
    await expectLater(
        loop.runTurn(const Input('hello', id: 'input'),
            onOutcome: (_) => throw failure),
        throwsA(same(failure)));
    await Future<void>.delayed(Duration.zero);
    expect(settled.single.stopReason, StopReason.error);
    expect(settled.single.detail, isNot(contains('callback failed')));
  });

  test('queued inputs settle once when an outcome callback drops the queue',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('done')]), plugins: []);
    final settled = <InputSettlement>[];
    final sub = loop.inputSettlements.listen(settled.add);
    addTearDown(sub.cancel);
    final run = loop.runTurn(const Input('first', id: 'first'), onOutcome: (_) {
      throw StateError('failure after first turn');
    });
    // Queue while the first turn is preparing, before provider work begins.
    expect(loop.offerInput(const Input('second', id: 'second')), isTrue);
    await expectLater(run, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(settled.map((s) => s.inputId), ['first', 'second']);
    expect(settled.map((s) => s.stopReason), everyElement(StopReason.error));
    expect(settled.last.started, isFalse);
    loop.cancel('late');
    await Future<void>.delayed(Duration.zero);
    expect(settled, hasLength(2));
  });
}
