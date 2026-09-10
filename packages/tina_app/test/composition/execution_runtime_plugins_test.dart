
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';

const _ledgerPluginId = 'tina.app.spend-ledger';
const _factoryPluginId = 'tina.app.provider-factory';

ProviderRegistry _registryWithUsageProvider() {
  final registry = ProviderRegistry(env: const {})
    ..register(
      ProviderDescriptor(
        id: 'test',
        name: 'Test',
        authSources: const [],
        defaultBaseUrl: 'https://example.test',
        builder: (c) => _UsageProvider(c.model),
      ),
    );
  return registry;
}

void main() {
  test('provider factory plugin activates after the spend ledger plugin',
      () async {
    final runtime = PluginRuntime(
      name: 'execution-test',
      plugins: [
        spendLedgerPlugin(RuntimeConfig()),
        providerFactoryPlugin(
          RuntimeConfig(),
          ProviderRegistry(env: const {}),
          PauseGate(),
        ),
      ],
    );
    await runtime.activate();
    addTearDown(runtime.dispose);

    expect(runtime.activationOrder, [_ledgerPluginId, _factoryPluginId]);
    expect(runtime.scope.lookup(spendLedgerServiceKey), isA<SpendLedger>());
    expect(
      runtime.scope.lookup(providerFactoryServiceKey),
      isA<RuntimeProviderFactory>(),
    );
  });

  test('a provider built from the runtime factory is metered into the ledger',
      () async {
    final registry = _registryWithUsageProvider();
    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
    );
    addTearDown(runtime.dispose);

    final provider = runtime.buildStartupProvider();
    try {
      await provider.send(system: '', messages: [], tools: []).drain<void>();
    } finally {
      provider.close();
    }
    // 7 input + 3 output tokens from the fake MessageComplete.
    expect(runtime.spendLedger.totalTokens, 10);
  });

  test('after dispose the runtime rejects new providers and dispose stays '
      'idempotent', () async {
    final registry = _registryWithUsageProvider();
    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
    );

    await runtime.dispose();
    expect(
      () => runtime.buildStartupProvider(),
      throwsA(isA<StateError>()),
    );
    // Second dispose returns the memoized teardown future — no throw.
    await runtime.dispose();
  });

  test('failed classifier provider build degrades to plain prompting and '
      'leaves nothing behind', () async {
    final registry = ProviderRegistry(env: const {})
      ..register(
        ProviderDescriptor(
          id: 'test',
          name: 'Test',
          authSources: const [],
          defaultBaseUrl: 'https://example.test',
          builder: (c) => throw StateError('provider build failed'),
        ),
      );
    // Must complete: the classifier build failure is caught and auto mode
    // degrades — the runtime scope (ledger + factory) rolls back nothing and
    // stays alive.
    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
    );
    addTearDown(runtime.dispose);

    expect(runtime.classifier, isNull);
    expect(runtime.spendLedger, isA<SpendLedger>());
  });

  test('runtimes for different project roots own independent tool scopes',
      () async {
    final rootA = await Directory.systemTemp.createTemp('tina_rt_a_');
    final rootB = await Directory.systemTemp.createTemp('tina_rt_b_');
    addTearDown(() async {
      await rootA.delete(recursive: true);
      await rootB.delete(recursive: true);
    });
    final registry = _registryWithUsageProvider();
    final runtimeA = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
      projectRoot: rootA.path,
    );
    addTearDown(runtimeA.dispose);
    final runtimeB = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
      projectRoot: rootB.path,
    );
    addTearDown(runtimeB.dispose);

    final scopeA = runtimeA.pipeline.tools;
    final scopeB = runtimeB.pipeline.tools;
    // Each runtime's plugins built their own scope — different roots, so the
    // write locks (and every tool instance) must be independent objects.
    expect(scopeA.projectRoot, rootA.path);
    expect(scopeB.projectRoot, rootB.path);
    expect(identical(scopeA, scopeB), isFalse);
    expect(identical(scopeA.mutationLock, scopeB.mutationLock), isFalse);
    Tool bashA(ToolRegistry r) => r.all.firstWhere((t) => t.schema.name == 'bash');
    expect(
      identical(
        bashA(scopeA.buildTools()),
        bashA(scopeB.buildTools()),
      ),
      isFalse,
    );
  });

  test('an explicitly borrowed toolScope is exposed as-is, with no own '
      'capabilities built', () async {
    final root = await Directory.systemTemp.createTemp('tina_rt_borrow_');
    addTearDown(() async => await root.delete(recursive: true));
    final borrowed = ProjectToolScope(
      projectRoot: root.path,
      env: const {},
    );
    final registry = _registryWithUsageProvider();
    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
      toolScope: borrowed,
    );
    addTearDown(runtime.dispose);

    // Same object identity: the runtime borrows, it does not rebuild.
    expect(identical(runtime.pipeline.tools, borrowed), isTrue);
    // The capability stage ran no plugins — nothing of its own was built.
    expect(runtime.pluginScope.lookup(projectCapabilitiesServiceKey), isNull);
    expect(runtime.pluginScope.lookup(projectToolScopeServiceKey), isNull);
  });

  test('the tool catalog is unchanged (search tools need keys in the env map)',
      () async {
    final root = await Directory.systemTemp.createTemp('tina_rt_catalog_');
    addTearDown(() async => await root.delete(recursive: true));
    final registry = _registryWithUsageProvider();
    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
      projectRoot: root.path,
    );
    addTearDown(runtime.dispose);

    expect(
      runtime.pipeline.tools.buildTools().all.map((t) => t.schema.name),
      [
        'read',
        'write',
        'edit',
        'fetch',
        'bash',
        'search',
        'grep',
        'glob',
        'ls',
        'stat',
        'which',
        'git',
      ],
    );
  });
}

class _UsageProvider extends LlmProvider {
  _UsageProvider(super.model);

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    yield const TextDelta('ALLOW');
    yield const MessageComplete(
      content: [TextBlock('ALLOW')],
      stopReason: 'end_turn',
      usage: TokenUsage(inputTokens: 7, outputTokens: 3),
    );
  }
}
