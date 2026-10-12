import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class Probe extends AgentPlugin {
  Probe(this.id,
      {this.failMount = false, this.failClose = false, this.command = 'probe'});
  @override
  final String id;
  final bool failMount, failClose;
  final String command;
  int seen = 0, closes = 0;
  @override
  List<Command> get commands =>
      [Command(name: command, description: 'probe', handler: (_) {})];
  @override
  List<ToolSchema> get tools =>
      [ToolSchema(name: 'probe_tool', description: 'probe', inputSchema: {})];
  @override
  void mountOn(AgentLoop loop) {
    loop.registerExecutor('probe_tool', (_) async => ToolResult('ok'));
    loop.subscribe((entry, event) {
      if (event == LogEvent.appended) seen++;
    });
    if (failMount) throw StateError('mount failed');
  }

  @override
  void closeSession() {
    closes++;
    if (failClose) throw StateError('close failed');
  }
}

final class PausedProvider extends LlmProvider {
  PausedProvider() : super('test');
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    entered.complete();
    await release.future;
    yield MessageComplete(content: [TextBlock('done')], stopReason: 'end_turn');
  }
}

const service = PluginCapability<AgentPlugin>('test/service');

void main() {
  Host host([List<AgentPlugin> plugins = const [], LlmProvider? provider]) {
    final result = Host.start(HostConfig(
        workingDirectory: '.',
        plugins: plugins,
        providerFactory: (_) =>
            provider ?? ScriptedProvider([scriptedReply('ok')])));
    addTearDown(result.close);
    return result;
  }

  test(
      'attachment lifecycle observers detach independently and roll back failed activation',
      () {
    final runtime = host();
    final registry = PluginRegistry<void>()
      ..register('test/probe', (_) => Probe('test/probe'),
          description: 'Test lifecycle observation.', live: true);
    final manager =
        PluginManager<void>(host: runtime, registry: registry, context: null);
    final first = <String>[], second = <String>[];
    final release = manager.listen(
        loaded: (p) => first.add('+${p.id}'),
        unloading: (p) => first.add('-${p.id}'));
    manager.listen(
        loaded: (p) => second.add('+${p.id}'),
        unloading: (p) => second.add('-${p.id}'));
    manager.select(['test/probe']);
    expect(first, ['+test/probe']);
    expect(second, first);
    release();
    manager.select([]);
    expect(first, ['+test/probe']);
    expect(second, ['+test/probe', '-test/probe']);
    final fail = manager.listen(
        loaded: (_) => throw StateError('view failed'), unloading: (_) {});
    manager.select(['test/probe']);
    expect(manager.lastError, contains('view failed'));
    expect(runtime.plugins.where((p) => p.id == 'test/probe'), isEmpty);
    expect(
        second, ['+test/probe', '-test/probe', '+test/probe', '-test/probe']);
    fail();
    manager.reconcile();
    expect(manager.lastError, isNull);
    expect(runtime.plugins.where((p) => p.id == 'test/probe'), hasLength(1));
  });

  test(
      'unload removes commands, executors and subscriptions; reload gets a fresh instance',
      () async {
    final instances = <Probe>[];
    final registry = PluginRegistry<void>()
      ..register('test/probe', (_) {
        final probe = Probe('test/probe');
        instances.add(probe);
        return probe;
      }, live: true, description: 'Test plugin registration.');
    final runtime = host();
    final manager =
        PluginManager(host: runtime, registry: registry, context: null);
    manager.select(['test/probe']);
    expect(runtime.commands['probe'], isNotNull);
    await runtime.send('one');
    final seen = instances.single.seen;
    expect(seen, greaterThan(0));
    manager.select([]);
    expect(runtime.commands['probe'], isNull);
    expect(instances.single.closes, 1);
    runtime.session.loop.recordUsage(const UsageRecordedEntry(turnId: 'test'));
    expect(instances.single.seen, seen);
    manager.select(['test/probe']);
    expect(manager.lastError, isNull); // no leaked executor collision
    expect(instances, hasLength(2));
    expect(runtime.plugins.single, same(instances.last));
  });

  test(
      'a failed mount cleans partial registrations and leaves previous plugins intact',
      () {
    final runtime = host();
    final probes = <Probe>[];
    var fail = true;
    final registry = PluginRegistry<void>()
      ..register('test/probe', (_) {
        final probe = Probe('test/probe', failMount: fail);
        probes.add(probe);
        return probe;
      }, live: true, description: 'Test plugin registration.');
    final manager =
        PluginManager(host: runtime, registry: registry, context: null);
    manager.select(['test/probe']);
    expect(manager.lastError, contains('mount failed'));
    expect(probes.single.closes, 1);
    expect(runtime.plugins, isEmpty);
    expect(runtime.commands['probe'], isNull);
    runtime.session.loop.recordUsage(const UsageRecordedEntry(turnId: 'test'));
    expect(probes.single.seen, 0);
    fail = false;
    manager.reconcile();
    expect(manager.lastError, isNull);
    expect(runtime.plugins, hasLength(1));
  });

  test(
      'command collision closes the new plugin without removing the existing command',
      () {
    final runtime = host();
    runtime.commands.publish(
        Command(name: 'probe', description: 'existing', handler: (_) {}));
    final probe = Probe('test/probe');
    final registry = PluginRegistry<void>()
      ..register('test/probe', (_) => probe,
          live: true, description: 'Test plugin registration.');
    final manager =
        PluginManager(host: runtime, registry: registry, context: null);
    manager.select(['test/probe']);
    expect(probe.closes, 1);
    expect(runtime.commands['probe']!.description, 'existing');
    expect(runtime.plugins, isEmpty);
    expect(manager.lastError, contains('already published'));
  });

  test('frontend activation failure rolls runtime registrations back', () {
    final runtime = host();
    final probe = Probe('test/probe');
    final registry = PluginRegistry<void>()
      ..register('test/probe', (_) => probe,
          live: true, description: 'Test plugin registration.');
    final manager =
        PluginManager(host: runtime, registry: registry, context: null)
          ..onLoaded = (_) => throw StateError('UI failed');
    manager.select(['test/probe']);
    expect(manager.lastError, contains('UI failed'));
    expect(runtime.commands['probe'], isNull);
    expect(probe.closes, 1);
  });

  test('changes requested during a turn wait until it finishes', () async {
    final provider = PausedProvider();
    final runtime = host([], provider);
    final registry = PluginRegistry<void>()
      ..register('test/probe', (_) => Probe('test/probe'),
          live: true, description: 'Test plugin registration.');
    final manager =
        PluginManager(host: runtime, registry: registry, context: null);
    final turn = runtime.send('hold');
    await provider.entered.future;
    manager.select(['test/probe']);
    expect(manager.waitingForIdle, true);
    expect(runtime.commands['probe'], isNull);
    provider.release.complete();
    await turn;
    expect(manager.waitingForIdle, false);
    expect(runtime.commands['probe'], isNotNull);
  });

  test('restart-only changes are reported without constructing plugins', () {
    final runtime = host();
    var built = false;
    final registry = PluginRegistry<void>()
      ..register('test/probe', (_) {
        built = true;
        return Probe('test/probe');
      }, description: 'Test plugin registration.');
    final manager =
        PluginManager(host: runtime, registry: registry, context: null);
    manager.select(['test/probe']);
    expect(built, false);
    expect(manager.pending, {'test/probe'});
  });

  test('cannot remove a capability provider while its consumer remains enabled',
      () {
    final registry = PluginRegistry<void>()
      ..registerDefinition(PluginDefinition<void>(
          'test/provider', (_) => Probe('test/provider'),
          provides: [service], description: 'Test plugin definition.'))
      ..registerDefinition(PluginDefinition.dependingOn<void, AgentPlugin>(
          'test/consumer',
          dependency: service,
          create: (_, provider) => Probe('test/consumer', command: 'consumer'),
          description: 'Test plugin definition.'));
    expect(() => registry.validate(['test/consumer']), throwsArgumentError);
  });
}
