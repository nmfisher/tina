
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
