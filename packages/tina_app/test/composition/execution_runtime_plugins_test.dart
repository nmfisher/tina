
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';

const _ledgerPluginId = 'tina.app.spend-ledger';
const _factoryPluginId = 'tina.app.provider-factory';

/// Witness key an extension binds from the borrowed tool scope; lets the
/// test prove the extension activated and which instance it received.
final ServiceKey<ProjectToolScope> _extensionToolScopeWitnessServiceKey =
    ServiceKey<ProjectToolScope>('test.extension.tool_scope_witness');

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

/// A plugin descriptor with NO provides and NO requires — the minimal
/// stand-in for an incomplete profile.
PluginDescriptor _barePlugin(String id) => PluginDescriptor(
      id: id,
      factory: FnPluginFactory((context) => Object()),
    );

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

  test('the default runtime mounts no provider decorator contributions',
      () async {
    final registry = _registryWithUsageProvider();
    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: registry,
      environment: FakeEnvironment(),
    );
    addTearDown(runtime.dispose);

    // No decorator plugin mounted (the default): the scope carries no
    // decorator contributions, so the factory's policy stack is metering
    // only — the pre-plugin composition.
    expect(providerDecoratorsFromScope(runtime.pluginScope), isEmpty);
  });

  test('a decorator contribution runs around the metered provider and '
      'metering still records every send', () async {
    var decorated = 0;
    var decoratedSends = 0;
    final runtime = PluginRuntime(
      name: 'execution-decorator-test',
      plugins: [
        spendLedgerPlugin(RuntimeConfig(provider: 'test', model: 'a')),
        providerDecoratorsPlugin([
          (inner) {
            decorated++;
            return _TaggedProvider(inner, () => decoratedSends++);
          },
        ]),
        providerFactoryPlugin(
          RuntimeConfig(provider: 'test', model: 'a'),
          _registryWithUsageProvider(),
          PauseGate(),
        ),
      ],
    );
    await runtime.activate();
    addTearDown(runtime.dispose);

    final factory = runtime.scope.lookup(providerFactoryServiceKey)!;
    final ledger = runtime.scope.lookup(spendLedgerServiceKey)!;
    final provider = factory.build('test/a');
    try {
      await provider.send(system: '', messages: [], tools: []).drain<void>();
    } finally {
      provider.close();
    }
    // The decorator contribution wrapped the provider once...
    expect(decorated, 1);
    // ...and its wrapper saw the send go through it...
    expect(decoratedSends, 1);
    // ...while metering still saw the same send (7 + 3 tokens).
    expect(ledger.totalTokens, 10);
  });

  test('the first declared decorator is the outermost wrapper', () async {
    final wrapped = <LlmProvider>[];
    _TaggedProvider? firstMarker;
    final runtime = PluginRuntime(
      name: 'execution-decorator-order-test',
      plugins: [
        spendLedgerPlugin(RuntimeConfig(provider: 'test', model: 'a')),
        providerDecoratorsPlugin([
          // Declared FIRST: the factory applies decorators in reverse, so this
          // runs LAST against the bare metering wrapper and ends up the
          // outermost custom layer.
          (inner) {
            wrapped.add(inner);
            return firstMarker = _TaggedProvider(inner, () {});
          },
          // Declared SECOND: applied FIRST, wrapping metering directly.
          (inner) {
            wrapped.add(inner);
            return _TaggedProvider(inner, () {});
          },
        ]),
        providerFactoryPlugin(
          RuntimeConfig(provider: 'test', model: 'a'),
          _registryWithUsageProvider(),
          PauseGate(),
        ),
      ],
    );
    await runtime.activate();
    addTearDown(runtime.dispose);

    final provider = runtime.scope.lookup(providerFactoryServiceKey)!.build(
          'test/a',
        );
    provider.close();

    expect(wrapped, hasLength(2));
    // The provider the factory hands out IS the first-declared decorator's
    // wrapper: first declared = outermost.
    expect(identical(provider, firstMarker), isTrue);
    // The first-declared wrapper's inner is the second-declared wrapper,
    // whose inner is the always-present metering layer.
    final second = firstMarker!.inner as _TaggedProvider;
    expect(second.inner, isA<MeteringProvider>());
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
    // The borrowed tool scope resolves through the borrowed parent scope —
    // still the lender's object, exposed to this runtime's plugins but never
    // rebuilt or owned here.
    expect(runtime.pluginScope.lookup(projectToolScopeServiceKey),
        same(borrowed));
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

  test('a borrowed tool scope satisfies an extension that requires '
      'projectToolScopeServiceKey, without being disposed by the borrower',
      () async {
    final root = await Directory.systemTemp.createTemp('tina_rt_borrow_req_');
    addTearDown(() async => await root.delete(recursive: true));
    var borrowedDisposals = 0;
    final borrowed = ProjectToolScope(
      projectRoot: root.path,
      env: const {},
    );
    // The borrowed scope's runtime owns the tool-scope service: validation
    // resolves the extension's requires edge through it, and nothing here
    // ever disposes the borrowed runtime.
    final ownerScope = borrowed.runtime.scope;
    // A resource the LENDER registered on its own scope. The borrower must
    // never release it: if it did, the lender's later teardown would dispose
    // the same resource twice.
    ownerScope.resources.own(() => borrowedDisposals++);

    final runtime = await buildExecutionRuntime(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registryWithUsageProvider(),
      environment: FakeEnvironment(),
      toolScope: borrowed,
      executionPlugins: [
        ...borrowedScopePlugins(
          defaultExecutionPlugins(
            config: RuntimeConfig(provider: 'test', model: 'a'),
            registry: _registryWithUsageProvider(),
            providerDecorators: const [],
            projectRoot: root.path,
            environment: FakeEnvironment(),
            sandboxEnabled: false,
            sandboxNet: false,
            sandboxReadOnly: false,
          ),
        ),
        // A conversation extension that needs the borrowed tool scope.
        PluginDescriptor(
          id: 'extension.needs-tool-scope',
          requires: {projectToolScopeServiceKey},
          provides: [_extensionToolScopeWitnessServiceKey],
          factory: FnPluginFactory((context) {
            final tools = context.require(projectToolScopeServiceKey);
            expect(identical(tools, borrowed), isTrue);
            return tools;
          }),
        ),
      ],
    );
    addTearDown(runtime.dispose);

    // Dependency validation succeeded (activation reached the extension and
    // the built runtime resolves the borrowed scope through the parent).
    expect(
      runtime.pluginScope.lookup(_extensionToolScopeWitnessServiceKey),
      same(borrowed),
    );
    expect(identical(runtime.pipeline.tools, borrowed), isTrue);

    // Borrowing must not transfer ownership: the borrowed resource stays
    // open while the borrower runs, and disposing the borrowing runtime
    // releases nothing of the lender's.
    expect(ownerScope.resources.isClosing, isFalse);
    await runtime.dispose();

    expect(ownerScope.state, ScopeLifecycleState.active,
        reason: 'the borrowed scope is never stopped by the borrower');
    expect(ownerScope.resources.isClosing, isFalse,
        reason: 'borrowing must not take over the resource');
    expect(borrowedDisposals, 0,
        reason: 'the borrowed resource must not be disposed a second time '
            'when the borrowing scope ends');
  });

  test('an incomplete profile fails BEFORE any factory runs, with a '
      'composition error naming the missing service', () async {
    final root = await Directory.systemTemp.createTemp('tina_rt_incomplete_');
    addTearDown(() => root.delete(recursive: true));
    var factoriesRan = 0;
    final incompleteProfile = [
      _barePlugin('only-a-bare-plugin'),
      // A plugin whose factory records that it ran — proving the failure
      // happens BEFORE activation, not mid-activation or after it.
      PluginDescriptor(
        id: 'side-effect-witness',
        factory: FnPluginFactory((context) {
          factoriesRan++;
          return Object();
        }),
      ),
    ];

    Object? failure;
    try {
      await buildExecutionRuntime(
        config: RuntimeConfig(provider: 'test', model: 'a'),
        registry: _registryWithUsageProvider(),
        environment: FakeEnvironment(),
        projectRoot: root.path,
        executionPlugins: incompleteProfile,
      );
    } catch (error) {
      failure = error;
    }

    expect(failure, isA<PluginCompositionError>());
    expect(
      failure.toString(),
      contains('tina.app.spend-ledger'),
      reason: 'the error names the missing required service',
    );
    expect(factoriesRan, 0,
        reason: 'validation happens before activation — no factory side '
            'effects precede the composition error');
  });

  test('a profile missing the tool-scope plugin leaves no acquired resource '
      'behind', () async {
    final root = await Directory.systemTemp.createTemp('tina_rt_toolscope_');
    addTearDown(() => root.delete(recursive: true));
    var resourcesAcquired = 0;
    var disposals = 0;
    // Everything the ledger/factory stages need, but WITHOUT the tool-scope
    // stage: composition must fail (before activation with the fix — the
    // regression this test pins), and the witness plugin proves whether any
    // acquisition survived the failure.
    final profileWithoutToolScope = [
      spendLedgerPlugin(RuntimeConfig(provider: 'test', model: 'a')),
      providerDecoratorsPlugin(const []),
      providerFactoryPlugin(
        RuntimeConfig(provider: 'test', model: 'a'),
        _registryWithUsageProvider(),
        PauseGate(),
      ),
      // The acquirer: a plugin that acquires one resource and registers its
      // cleanup on the runtime scope — a stand-in for every activation-time
      // acquisition the mounted stages perform.
      PluginDescriptor(
        id: 'acquirer.witness',
        factory: FnPluginFactory((context) {
          resourcesAcquired++;
          context.own(() => disposals++);
          return Object();
        }),
      ),
    ];

    Object? failure;
    try {
      await buildExecutionRuntime(
        config: RuntimeConfig(provider: 'test', model: 'a'),
        registry: _registryWithUsageProvider(),
        environment: FakeEnvironment(),
        projectRoot: root.path,
        executionPlugins: profileWithoutToolScope,
      );
    } catch (error) {
      failure = error;
    }

    expect(failure, isA<PluginCompositionError>(),
        reason: 'the missing tool scope is a composition error');
    expect(
      failure.toString(),
      contains('project tool scope'),
      reason: 'the error names the missing tool-scope stage',
    );
    // Regression invariant: zero resources remain acquired. Validation now
    // runs BEFORE activation, so the acquirer never even runs (and if any
    // stage were ever to acquire before this validation, the teardown armed
    // up front would still release it).
    expect(resourcesAcquired - disposals, 0,
        reason: 'every acquired resource must be released when composition '
            'fails — zero may remain acquired');
    expect(disposals, 0,
        reason: 'with the fix the composition fails before activation, so '
            'the witness acquirer is never reached at all');
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

/// A decorator wrapper that forwards to [inner] and fires [onSend] on every
/// send — lets the decorator tests observe both wrap order and that sends
/// actually traverse each declared layer.
class _TaggedProvider extends LlmProvider {
  final LlmProvider inner;
  final void Function() onSend;

  _TaggedProvider(this.inner, this.onSend) : super(inner.model);

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    onSend();
    return inner.send(system: system, messages: messages, tools: tools);
  }

  @override
  void close() => inner.close();
}
