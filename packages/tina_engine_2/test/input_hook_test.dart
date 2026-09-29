import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

class DelayedInput extends AgentPlugin {
  final ready = Completer<void>();
  final release = Completer<void>();
  bool fail = false;
  @override
  String get id => 'test/delayed';
  @override
  Future<void> onInput(TurnContext context) async {
    if (ready.isCompleted) return;
    ready.complete();
    await release.future;
    context.input = Input('rewritten', id: context.input.id);
    if (fail) throw StateError('failed hook');
  }
}

void main() {
  test('async input writes commit only when the hook finishes', () async {
    final plugin = DelayedInput();
    final provider = ScriptedProvider([]);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    final turn = loop.runTurn(const Input('original', id: '1'));
    await plugin.ready.future;
    expect(provider.callCount, 0);
    expect(loop.log.whereType<MessageAppendedEntry>(), isEmpty);
    plugin.release.complete();
    await turn;
    expect(
        (provider.requests.single.messages.last.content.single as TextBlock)
            .text,
        'rewritten');
  });
  test('cancellation interrupts a stuck hook and late writes stay isolated',
      () async {
    final plugin = DelayedInput();
    final provider = ScriptedProvider([]);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    final turn = loop.runTurn(const Input('original', id: '1'));
    await plugin.ready.future;
    loop.cancel('escape');
    expect((await turn.timeout(const Duration(seconds: 1))).stopReason,
        StopReason.cancelled);
    expect(provider.callCount, 0);
    plugin.release.complete();
    await loop.runTurn(const Input('next', id: '2'));
    expect(
        (provider.requests.single.messages.last.content.single as TextBlock)
            .text,
        'next');
    expect(loop.log.whereType<InputRewrittenEntry>(), isEmpty);
  });
  test('failed async hooks discard their mutations like synchronous hooks',
      () async {
    final plugin = DelayedInput()..fail = true;
    final provider = ScriptedProvider([]);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    final turn = loop.runTurn(const Input('original', id: '1'));
    await plugin.ready.future;
    plugin.release.complete();
    final outcome = await turn;
    expect(outcome.stopReason, StopReason.error);
    expect(provider.requests, isEmpty);
    expect(outcome.messages, isEmpty);
    expect(loop.log.whereType<InputRewrittenEntry>(), isEmpty);
  });
}
