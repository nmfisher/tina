import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

class DiscoveryPlugin extends AgentPlugin {
  DiscoveryPlugin(this.prepare);
  final Future<void> Function(TurnContext) prepare;
  final schemas = <ToolSchema>[];
  @override
  String get id => 'test/discovery';
  @override
  List<ToolSchema> get tools => schemas;
  @override
  Future<void> prepareTurn(TurnContext context) => prepare(context);
}

void main() {
  test('asynchronously discovered tools are available in the first request',
      () async {
    late DiscoveryPlugin plugin;
    plugin = DiscoveryPlugin((context) async {
      await Future<void>.delayed(Duration.zero);
      plugin.schemas.add(
          const ToolSchema(name: 'found', description: '', inputSchema: {}));
    });
    final provider = ScriptedProvider([scriptedReply('ok')]);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    final result = await loop.runTurn(const Input('go', id: 'one'));
    expect(result.modelRequests.single.tools.single.name, 'found');
  });
  test('discovery failure closes the logged turn before any model request',
      () async {
    final provider = ScriptedProvider([]);
    final loop = AgentLoop(provider: provider, plugins: [
      DiscoveryPlugin((_) async => throw StateError('private payload')),
    ]);
    final result = await loop.runTurn(const Input('go', id: 'one'));
    expect(result.stopReason, StopReason.error);
    expect(provider.callCount, 0);
    expect(loop.log.whereType<TurnStartedEntry>(), hasLength(1));
    expect(loop.log.whereType<TurnEndedEntry>(), hasLength(1));
    expect(loop.hookFailures.single.phase, 'prepareTurn');
    expect(result.detail, isNot(contains('private payload')));
  });
  test('cancellation interrupts discovery and observes late failures',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    final provider = ScriptedProvider([]);
    final loop = AgentLoop(provider: provider, plugins: [
      DiscoveryPlugin((_) async {
        entered.complete();
        await release.future;
        throw StateError('late');
      }),
    ]);
    final turn = loop.runTurn(const Input('go', id: 'one'));
    await entered.future;
    loop.cancel('escape');
    expect((await turn).stopReason, StopReason.cancelled);
    expect(provider.callCount, 0);
    release.complete();
    await Future<void>.delayed(Duration.zero);
  });
}
