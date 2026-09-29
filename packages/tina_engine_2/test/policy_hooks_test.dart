import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

class Hook extends AgentPlugin {
  Hook(this.id, {this.input, this.before, this.guard, this.end});
  @override
  final String id;
  final FutureOr<void> Function(TurnContext)? input, before, guard, end;
  @override
  FutureOr<void> onInput(TurnContext c) => input?.call(c);
  @override
  FutureOr<void> beforeModelCall(TurnContext c) => before?.call(c);
  @override
  FutureOr<void> beforeToolCall(TurnContext c) => guard?.call(c);
  @override
  FutureOr<void> onTurnEnd(TurnContext c) => end?.call(c);
  @override
  List<ToolSchema> get tools => id == 'test/a'
      ? [const ToolSchema(name: 'echo', description: '', inputSchema: {})]
      : [];
}

void main() {
  test('stop attribution comes from invoking plugin and survives JSON replay',
      () async {
    final provider = ScriptedProvider([]);
    final loop = AgentLoop(provider: provider, plugins: [
      Hook('test/a', before: (c) {
        c.requestStop('spoofed/id', 'quota', detail: 'done for now');
      })
    ]);
    final outcome = await loop.runTurn(const Input('go', id: 'one'));
    expect(provider.callCount, 0);
    expect(outcome.stopReason, StopReason.cancelled);
    expect(outcome.detail, 'done for now');
    expect(outcome.stopRequest!.pluginId, 'test/a');
    final ended = loop.log.whereType<TurnEndedEntry>().single;
    final decoded = SessionEntry.fromJson(ended.toJson()) as TurnEndedEntry;
    expect(decoded, ended);
    expect(decoded.stop,
        {'plugin_id': 'test/a', 'code': 'quota', 'detail': 'done for now'});
    final legacy = Map<String, dynamic>.from(ended.toJson())..remove('stop');
    expect((SessionEntry.fromJson(legacy) as TurnEndedEntry).stop, isNull);
  });

  test('async guard failure prevents the entire tool batch', () async {
    var executed = 0;
    final loop = AgentLoop(
        provider: ScriptedProvider([
          scriptedReply('', calls: [
            for (final id in ['a', 'b'])
              ToolUseBlock(id: id, name: 'echo', input: {})
          ]),
          scriptedReply('done')
        ]),
        plugins: [
          Hook('test/a', guard: (_) async {
            await Future<void>.delayed(Duration.zero);
            throw StateError('private payload');
          })
        ]);
    loop.registerExecutor('echo', (_) async {
      executed++;
      return const ToolResult('ok');
    });
    final outcome = await loop.runTurn(const Input('go', id: 'one'));
    expect(executed, 0);
    final results =
        outcome.messages.expand((m) => m.content).whereType<ToolResultBlock>();
    expect(results.map((r) => r.toolUseId), ['a', 'b']);
    expect(results.every((r) => r.isError), isTrue);
    expect(results.map((r) => r.content).join(),
        isNot(contains('private payload')));
  });

  test(
      'cancellation interrupts a pending guard, closes batch, observes late error',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var executed = 0;
    var cleanedUp = false;
    final loop = AgentLoop(
        provider: ScriptedProvider([
          scriptedReply('', calls: [
            for (final id in ['a', 'b'])
              ToolUseBlock(id: id, name: 'echo', input: {})
          ])
        ]),
        plugins: [
          Hook('test/a', guard: (_) async {
            entered.complete();
            await release.future;
            throw StateError('late');
          }, end: (_) async {
            await Future<void>.delayed(Duration.zero);
            cleanedUp = true;
          })
        ]);
    loop.registerExecutor('echo', (_) async {
      executed++;
      return const ToolResult('ok');
    });
    final turn = loop.runTurn(const Input('go', id: 'one'));
    await entered.future;
    loop.cancel('escape');
    final outcome = await turn.timeout(const Duration(seconds: 2));
    expect(outcome.stopReason, StopReason.cancelled);
    expect(executed, 0);
    expect(cleanedUp, isTrue);
    expect(
        outcome.messages.expand((m) => m.content).whereType<ToolResultBlock>(),
        hasLength(2));
    release.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('stop in guard blocks executor and remaining calls with paired results',
      () async {
    var executed = 0;
    final loop = AgentLoop(
        provider: ScriptedProvider([
          scriptedReply('', calls: [
            for (final id in ['a', 'b'])
              ToolUseBlock(id: id, name: 'echo', input: {})
          ])
        ]),
        plugins: [
          Hook('test/a', guard: (c) => c.requestStop('test/a', 'blocked'))
        ]);
    loop.registerExecutor('echo', (_) async {
      executed++;
      return const ToolResult('ok');
    });
    final outcome = await loop.runTurn(const Input('go', id: 'one'));
    expect(executed, 0);
    expect(outcome.stopRequest!.code, 'blocked');
    expect(
        outcome.messages.expand((m) => m.content).whereType<ToolResultBlock>(),
        hasLength(2));
  });
}
