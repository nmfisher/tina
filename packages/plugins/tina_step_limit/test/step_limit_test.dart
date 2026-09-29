import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_step_limit/tina_step_limit.dart';

final class Echo extends AgentPlugin {
  @override
  String get id => 'test/echo';
  @override
  List<ToolSchema> get tools =>
      [const ToolSchema(name: 'echo', description: 'echo', inputSchema: {})];
}

List<StreamEvent> round(int n, {int tools = 1}) => scriptedReply('', calls: [
      for (var i = 0; i < tools; i++)
        ToolUseBlock(id: '$n-$i', name: 'echo', input: {}),
    ]);

AgentLoop loopFor(ScriptedProvider provider, [StepLimitPlugin? limit]) {
  final loop = AgentLoop(
      provider: provider, plugins: [Echo(), if (limit != null) limit]);
  loop.registerExecutor('echo', (_) async => const ToolResult('ok'));
  return loop;
}

void main() {
  test('invalid config fails before any foreground request', () async {
    final provider = ScriptedProvider([scriptedReply('unreachable')]);
    final outcome =
        await loopFor(provider, StepLimitPlugin(readLimit: () => -1))
            .runTurn(const Input('go', id: 'invalid'));
    expect(outcome.stopReason, StopReason.error);
    expect(provider.callCount, 0);
  });

  test('resume starts a fresh allowance and keeps completed tool history',
      () async {
    final first = loopFor(
        ScriptedProvider([round(1)]), StepLimitPlugin(maxStepsPerTurn: 1));
    await first.runTurn(const Input('go', id: 'one'));
    final provider = ScriptedProvider([scriptedReply('finished')]);
    final resumed = AgentLoop(
        provider: provider,
        plugins: [Echo(), StepLimitPlugin(maxStepsPerTurn: 1)],
        seedLog: first.log);
    final outcome = await resumed.runTurn(const Input('continue', id: 'two'));
    expect(outcome.stopReason, StopReason.complete);
    expect(provider.callCount, 1);
    expect(
        provider.requests.single.messages
            .expand((m) => m.content)
            .whereType<ToolResultBlock>(),
        hasLength(1));
  });

  test('user cancellation takes precedence and resets next turn', () async {
    final provider = ScriptedProvider([round(1), scriptedReply('done')]);
    final loop = loopFor(provider, StepLimitPlugin(maxStepsPerTurn: 1));
    loop.registerExecutor('echo', (_) async {
      loop.cancel('user stopped');
      return const ToolResult('ok');
    });
    final cancelled = await loop.runTurn(const Input('go', id: 'one'));
    expect(cancelled.stopReason, StopReason.cancelled);
    expect(cancelled.detail, contains('user stopped'));
    expect((await loop.runTurn(const Input('continue', id: 'two'))).stopReason,
        StopReason.complete);
  });

  test('no plugin and zero limit both allow more than 16 rounds', () async {
    for (final plugin in [null, StepLimitPlugin()]) {
      final provider = ScriptedProvider(
          [for (var i = 0; i < 24; i++) round(i), scriptedReply('done')]);
      final outcome =
          await loopFor(provider, plugin).runTurn(const Input('go', id: 'one'));
      expect(outcome.stopReason, StopReason.complete);
      expect(provider.callCount, 25);
    }
  });

  test('final answer at exactly N succeeds', () async {
    final provider = ScriptedProvider([round(1), scriptedReply('done')]);
    final outcome = await loopFor(provider, StepLimitPlugin(maxStepsPerTurn: 2))
        .runTurn(const Input('go', id: 'one'));
    expect(outcome.stopReason, StopReason.complete);
    expect(provider.callCount, 2);
  });

  test('records every tool in Nth round and stops before N+1', () async {
    final provider =
        ScriptedProvider([round(1, tools: 3), scriptedReply('unreachable')]);
    final loop = loopFor(provider, StepLimitPlugin(maxStepsPerTurn: 1));
    final outcome = await loop.runTurn(const Input('go', id: 'one'));
    expect(outcome.stopReason, isNot(StopReason.error));
    expect(outcome.detail, contains('limit (1)'));
    expect(provider.callCount, 1);
    expect(
        outcome.messages.expand((m) => m.content).whereType<ToolResultBlock>(),
        hasLength(3));
    expect(loop.log.whereType<TurnEndedEntry>(), hasLength(1));
  });

  test('snapshots settings per turn and resets on next input', () async {
    var allowance = 2;
    final provider = ScriptedProvider([
      round(1),
      scriptedReply('done'),
      round(2),
      scriptedReply('unreachable')
    ]);
    final loop = loopFor(provider, StepLimitPlugin(readLimit: () => allowance));
    loop.registerExecutor('echo', (_) async {
      allowance = 1;
      return const ToolResult('ok');
    });
    expect((await loop.runTurn(const Input('first', id: 'one'))).stopReason,
        StopReason.complete);
    final second = await loop.runTurn(const Input('second', id: 'two'));
    expect(second.detail, contains('limit (1)'));
    expect(provider.callCount, 3);
  });

  test('separate sessions have separate counters and unloading removes policy',
      () async {
    for (var i = 0; i < 2; i++) {
      final provider = ScriptedProvider([
        round(1),
        for (var j = 0; j < 20; j++) round(j + 2),
        scriptedReply('done')
      ]);
      final loop = loopFor(provider);
      loop.addPlugin(StepLimitPlugin(maxStepsPerTurn: 1));
      expect((await loop.runTurn(const Input('first', id: 'one'))).detail,
          contains('limit (1)'));
      loop.removePlugin('tina/step-limit');
      expect(
          (await loop.runTurn(const Input('continue', id: 'two'))).stopReason,
          StopReason.complete);
      expect(provider.callCount, 22);
    }
  });
}
