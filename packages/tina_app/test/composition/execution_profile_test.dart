import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';

const _ledgerPluginId = 'tina.app.spend-ledger';
const _decoratorsPluginId = 'tina.app.provider-decorators';
const _factoryPluginId = 'tina.app.provider-factory';
const _capabilitiesPluginId = 'tina.engine.project-capabilities';
const _toolScopePluginId = 'tina.engine.project-tool-scope';

ProviderRegistry _registryWithUsageProvider({
  void Function()? onBuilderCalled,
}) {
  final registry = ProviderRegistry(env: const {})
    ..register(
      ProviderDescriptor(
        id: 'test',
        name: 'Test',
        authSources: const [],
        defaultBaseUrl: 'https://example.test',
        builder: (c) {
          onBuilderCalled?.call();
          return _UsageProvider(c.model);
        },
      ),
    );
  return registry;
}

Future<Directory> _tempProject() async {
  final root = await Directory.systemTemp.createTemp('tina_profile_');
  return root;
}

List<PluginDescriptor> _defaultProfile() {
  final root = Directory.systemTemp.createTempSync('tina_profile_sync_');
  addTearDown(() => root.delete(recursive: true));
  return defaultExecutionPlugins(
    config: RuntimeConfig(provider: 'test', model: 'a'),
    registry: ProviderRegistry(env: const {}),
    providerDecorators: const [],
    projectRoot: root.path,
    environment: FakeEnvironment(),
    sandboxEnabled: RuntimeConfig().sandboxEnabled,
    sandboxNet: RuntimeConfig().sandboxNet,
    sandboxReadOnly: RuntimeConfig().sandboxReadOnly,
  );
}

void main() {
  test('the default profile lists exactly the five plugins in declared order',
      () {
    final plugins = _defaultProfile();
    expect(
      [for (final plugin in plugins) plugin.id],
      [
        _ledgerPluginId,
        _decoratorsPluginId,
        _factoryPluginId,
        _capabilitiesPluginId,
        _toolScopePluginId,
      ],
    );
  });

  test(
      'the default profile activates in a bare runtime — no missing '
      'dependencies', () async {
    final plugins = _defaultProfile();
    final description = PluginRuntime(
      name: 'execution',
      plugins: plugins,
    ).describe();
    // Diagnostics first: no pending missing-dependency error, nothing wired.
    expect(
      [for (final plugin in description.plugins) plugin.state],
      everyElement(PluginLifecycleState.pending),
    );
    expect(description.activationOrder, isEmpty);

    // Then the real thing on a throwaway runtime with a throwaway project.
    final root = await _tempProject();
    addTearDown(() => root.delete(recursive: true));
    final runtime = PluginRuntime(
      name: 'execution',
      plugins: defaultExecutionPlugins(
        config: RuntimeConfig(provider: 'test', model: 'a'),
        registry: ProviderRegistry(env: const {}),
        providerDecorators: const [],
        projectRoot: root.path,
        environment: FakeEnvironment(),
        sandboxEnabled: RuntimeConfig().sandboxEnabled,
        sandboxNet: RuntimeConfig().sandboxNet,
        sandboxReadOnly: RuntimeConfig().sandboxReadOnly,
      ),
    );
    await runtime.activate();
    addTearDown(runtime.dispose);

    expect(
      runtime.scope.lookup(spendLedgerServiceKey),
      isA<SpendLedger>(),
    );
    expect(
      runtime.scope.lookup(providerFactoryServiceKey),
      isA<RuntimeProviderFactory>(),
    );
    expect(
      runtime.scope.lookup(projectCapabilitiesServiceKey),
      isNotNull,
    );
    expect(runtime.scope.lookup(projectToolScopeServiceKey), isNotNull);
  });

  test('buildExecutionRuntime with the default profile exposes every service',
      () async {
    final root = await _tempProject();
    addTearDown(() => root.delete(recursive: true));
    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registryWithUsageProvider(),
      environment: FakeEnvironment(),
      projectRoot: root.path,
    );
    addTearDown(runtime.dispose);

    expect(runtime.spendLedger, isA<SpendLedger>());
    expect(runtime.pluginScope.lookup(projectToolScopeServiceKey), isNotNull);
  });

  test('a duplicate plugin id in an override fails before any provider is '
      'built', () async {
    var builderCalls = 0;
    final registry =
        _registryWithUsageProvider(onBuilderCalled: () => builderCalls++);
    final root = await _tempProject();
    addTearDown(() => root.delete(recursive: true));

    final plugins = defaultExecutionPlugins(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      providerDecorators: const [],
      projectRoot: root.path,
      environment: FakeEnvironment(),
      sandboxEnabled: true,
      sandboxNet: false,
      sandboxReadOnly: false,
    );
    // Duplicate the ledger plugin: two providers of the ledger key with no
    // selection -> a composition error at validate time.
    final overridden = [...plugins, plugins.first];

    await expectLater(
      buildExecutionRuntime(
        config: RuntimeConfig(provider: 'test', model: 'a'),
        registry: registry,
        environment: FakeEnvironment(),
        projectRoot: root.path,
        executionPlugins: overridden,
      ),
      throwsA(isA<PluginCompositionError>()),
    );
    expect(builderCalls, 0);
  });

  test('an override without the tool-scope plugin fails before any provider '
      'is built', () async {
    var builderCalls = 0;
    final registry =
        _registryWithUsageProvider(onBuilderCalled: () => builderCalls++);
    final root = await _tempProject();
    addTearDown(() => root.delete(recursive: true));

    final plugins = defaultExecutionPlugins(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      providerDecorators: const [],
      projectRoot: root.path,
      environment: FakeEnvironment(),
      sandboxEnabled: true,
      sandboxNet: false,
      sandboxReadOnly: false,
    );
    final overridden = [
      ...plugins.where((plugin) => plugin.id != _toolScopePluginId),
    ];

    final built = buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
      projectRoot: root.path,
      executionPlugins: overridden,
    );

    Object? failure;
    try {
      await built;
    } catch (error) {
      failure = error;
    }

    // Either the runtime activation itself failed, or the subsequent scope
    // lookup reported the missing tool scope — in BOTH cases the provider
    // descriptor builder was never invoked and the failure is the runtime's
    // own composition error, not an unrelated crash.
    expect(failure, isA<PluginCompositionError>());
    expect(builderCalls, 0);
  });

  group('borrowedScopePlugins', () {
    test('drops exactly the project-owned stages, keeps the conversation '
        'prefix', () {
      final borrowed = borrowedScopePlugins(_defaultProfile());
      expect(
        [for (final plugin in borrowed) plugin.id],
        [
          _ledgerPluginId,
          _decoratorsPluginId,
          _factoryPluginId,
        ],
        reason: 'capabilities + tool scope stay with the owner',
      );
    });

    test('keeps conversation extensions the allowlist never knew about '
        '(regression: borrowed runtime lost its driver factory)', () {
      final factory = _CountingDriverFactory();
      final extended = [..._defaultProfile(), driverPlugin(factory)];
      final borrowed = borrowedScopePlugins(extended);
      expect(
        [for (final plugin in borrowed) plugin.id],
        contains('tina.engine.driver'),
        reason: 'a custom conversation plugin must survive the borrow trim',
      );
      expect(
        [for (final plugin in borrowed) plugin.id],
        isNot(contains(_capabilitiesPluginId)),
      );
    });
  });

  test('a borrowed runtime with a driver-extension profile resolves the '
      'factory on its scheduler', () async {
    final root = await _tempProject();
    addTearDown(() => root.delete(recursive: true));
    final borrowed = ProjectToolScope(projectRoot: root.path, env: const {});
    final factory = _CountingDriverFactory();
    final extended = [
      ...defaultExecutionPlugins(
        config: RuntimeConfig(provider: 'test', model: 'a'),
        registry: _registryWithUsageProvider(),
        providerDecorators: const [],
        projectRoot: root.path,
        environment: FakeEnvironment(),
        sandboxEnabled: RuntimeConfig().sandboxEnabled,
        sandboxNet: RuntimeConfig().sandboxNet,
        sandboxReadOnly: RuntimeConfig().sandboxReadOnly,
      ),
      driverPlugin(factory),
    ];
    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registryWithUsageProvider(),
      environment: FakeEnvironment(),
      toolScope: borrowed,
      executionPlugins: extended,
    );
    addTearDown(runtime.dispose);

    expect(runtime.scheduler.driverFactory, same(factory),
        reason: 'the borrowed runtime mounted the extension-provided '
            'driver factory — the old allowlist resolved null here');
    expect(identical(runtime.pipeline.tools, borrowed), isTrue,
        reason: 'the borrow semantics are unchanged');
  });
}

/// A driver factory that counts create() calls and defers to the default.
class _CountingDriverFactory implements AgentDriverFactory {
  int calls = 0;

  @override
  AgentDriver create(AgentDriverRequest request) {
    calls++;
    return const DefaultAgentDriverFactory().create(request);
  }
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
