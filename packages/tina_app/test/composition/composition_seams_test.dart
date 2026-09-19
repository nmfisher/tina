import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';
import '../helpers/memory_session_store.dart';
import '../helpers/fake_host_interface.dart';

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

/// A driver that replays nothing and records the request it was built from —
/// just enough [AgentDriver] to prove the composition hands THIS driver (not
/// the built-in agent loop) to the scheduler.
class _ScriptedDriver implements AgentDriver {
  final AgentDriverRequest request;

  _ScriptedDriver(this.request);

  @override
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
    HistoryAppendObserver? onHistoryAppend,
    HistoryReplaceObserver? onHistoryReplace,
  }) async {}

  @override
  String? get abortedReason => null;

  @override
  AbortedKind get abortedKind => AbortedKind.none;

  /// The scripted driver drives no real agent — the contract no longer asks
  /// for one, so nothing reaches past the driver.

  @override
  String get system => request.system;

  @override
  ToolRegistry get tools => request.tools;

  @override
  LlmProvider get provider => request.provider;

  @override
  set provider(LlmProvider value) {}

  @override
  Future<bool> compact(
    List<Message> history, {
    int preserveRecent = 0,
    int preserveRecentMessages = 0,
    Future<void>? cancelSignal,
  }) async => false;
}

class _ScriptedDriverFactory implements AgentDriverFactory {
  /// Every driver this factory built (one per scheduler-spawned agent).
  final List<_ScriptedDriver> created = [];

  @override
  AgentDriver create(AgentDriverRequest request) {
    final driver = _ScriptedDriver(request);
    created.add(driver);
    return driver;
  }
}

/// Mints a real [SessionRecorder] over the given store for every persisted
/// sub-agent session and records the spawn it was consulted for. The factory
/// is a plain function (a typedef), so identity is closure identity.
class _ScriptedPersistence {
  final SessionStore store;

  /// `(conversationId, parentConversationId, label)` per call.
  final List<(String, String, String)> calls = [];

  _ScriptedPersistence(this.store);

  SubAgentPersistenceFactory get factory => (
        SubAgentJob job, {
        required ConversationMetaInput meta,
        required String parentConversationId,
      }) async {
        final conversationId = 'p${calls.length}';
        calls.add((conversationId, parentConversationId, meta.label));
        return (
          conversationId,
          SessionRecorder(store, 'scripted-session', conversationId,
              providerId: 'test', meta: meta),
        );
      };
}

Future<AppComposition> _build({
  AgentDriverFactory? driverFactory,
  SubAgentPersistenceFactory? persistence,
}) =>
    buildAppComposition(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registryWithUsageProvider(),
      store: MemorySessionStore(),
      environment: FakeEnvironment(),
      driverFactory: driverFactory,
      persistence: persistence,
    );

void main() {
  test(
      'buildAppComposition mounts a scripted driver factory on the composition '
      'AND the scheduler (one object throughout)', () async {
    final factory = _ScriptedDriverFactory();
    final comp = await _build(driverFactory: factory);
    addTearDown(comp.dispose);

    // Stored on the composition…
    expect(comp.driverFactory, same(factory));
    // …and mounted on the scheduler it built — the identical object, so one
    // choice at the composition root governs every scheduler-built agent.
    expect(comp.scheduler.driverFactory, same(factory));
    expect(identical(comp.driverFactory, comp.scheduler.driverFactory), isTrue);

    // The factory is consulted per spawned agent, not at build time: nothing
    // was created while composing the app.
    expect(factory.created, isEmpty);
  });

  test(
      'buildAppComposition mounts a persistence factory on the composition '
      'AND the scheduler (one object throughout)', () async {
    final store = MemorySessionStore();
    final persistence = _ScriptedPersistence(store);
    // Capture the closure once: `factory` mints a fresh one per read, and the
    // identity chain must hold for the exact object handed to the builder.
    final persistenceFactory = persistence.factory;
    final comp = await buildAppComposition(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registryWithUsageProvider(),
      store: store,
      environment: FakeEnvironment(),
      persistence: persistenceFactory,
    );
    addTearDown(comp.dispose);

    // Stored on the composition…
    expect(comp.persistence, same(persistenceFactory));
    // …and wired onto the scheduler it built — the identical object, so one
    // choice at the composition root governs every session-recording
    // sub-agent.
    expect(comp.scheduler.persistence, same(persistenceFactory));
    expect(
        identical(comp.persistence, comp.scheduler.persistence), isTrue);

    // Wiring only: the factory is invoked when a job spawns, never at build.
    expect(persistence.calls, isEmpty);
  });

  test(
      'defaults: without the params both seams stay null and the built-in '
      'behavior is intact', () async {
    final comp = await _build();
    addTearDown(comp.dispose);

    expect(comp.driverFactory, isNull);
    expect(comp.persistence, isNull);
    // The scheduler falls back to its built-in loop and in-memory-only
    // transcripts.
    expect(comp.scheduler.driverFactory, isNull);
    expect(comp.scheduler.persistence, isNull);

    // The composition still resolved a usable session over the wired
    // primitives.
    expect(comp.initialSessionId, isNotEmpty);
    expect(comp.scheduler.registry, same(comp.registry));
    expect(comp.scheduler.pipeline, same(comp.pipeline));

    // dispose() works — and stays idempotent.
    await comp.dispose();
    await comp.dispose();
  });
  group('orchestrator tool set', () {
    for (final delegates in [false, true]) {
      test('composition restricts orchestrator withSubAgents=$delegates', () async {
        final factory = ProbeFactory();
        final provider = Provider();
        final registry = ProviderRegistry(env: const {})
          ..register(
            ProviderDescriptor(
              id: 'test',
              name: 'Test',
              authSources: const [],
              defaultBaseUrl: 'https://example.test',
              builder: (_) => provider,
            ),
          );
        final comp = await buildAppComposition(
          config: RuntimeConfig(provider: 'test', model: 'test'),
          registry: registry,
          store: MemorySessionStore(),
          environment: FakeEnvironment(),
          driverFactory: factory,
        );
        addTearDown(comp.dispose);
        final host = FakeHostInterface();
        addTearDown(host.dispose);
        var approvals = 0;
        final driver = buildAgent(
          pipeline: comp.pipeline,
          scheduler: comp.scheduler,
          conversationId: comp.initialConversationId,
          provider: provider,
          host: host,
          policy: comp.policy,
          config: comp.config,
          withSubAgents: delegates,
          toolAccess: AgentToolAccess.orchestrator,
          asker: (_) async {
            approvals++;
            return PermissionResponse.allowOnce;
          },
        );
        expect(driver.tools.schemas.map((s) => s.name), ['ask_user']);
        for (final name in [
          'bash',
          'exec',
          'read',
          'grep',
          'list_files',
          'delegate',
          'launch_workflow',
          'read_summary',
          'environment_stage',
          'plugin_fs_alias',
        ]) {
          expect(
            combineGuardBlocks(factory.request.executionGuards, name, {}),
            isNotNull,
          );
          expect(driver.tools.executionBlock(name, {}), isNotNull);
        }
        // A per-turn catalog replacement cannot bypass the execution restriction.
        final probe = ProbeTool();
        final history = <Message>[];
        comp.policy.mode = PermissionMode.allowEdits;
        await driver.run(
          history: history,
          userInput: 'inspect',
          turnTools: ToolRegistry([probe]),
        );
        expect(probe.calls, 0);
        expect(approvals, 0);
        final denied = history
            .expand((m) => m.content)
            .whereType<ToolResultBlock>()
            .single;
        expect(denied.isError, isTrue);
        expect(denied.content, contains('This orchestrator cannot access'));
        // Building a sibling in the same scheduler does not inherit this role.
        final sibling = buildAgent(
          pipeline: comp.pipeline,
          scheduler: comp.scheduler,
          conversationId: 'sibling',
          provider: Provider(),
          host: host,
          policy: comp.policy,
          config: comp.config,
          withSubAgents: false,
        );
        expect(sibling.tools['read'], isNotNull);
        expect(
          factory.request.executionGuards.whereType<OrchestratorToolGuard>(),
          isEmpty,
        );
      });
    }
  });
  group('driver seam, live', () {
    test(
      'the composed driver runs the turn; the built-in agent never does '
      '(driver-only conversation)',
      () async {
        _RecordingProvider.reset();
        final factory = _ScriptedDriverFactory_merged();
        final comp = await _build_merged(factory);
        addTearDown(comp.dispose);

        final host = FakeHostInterface();
        addTearDown(host.dispose);

        // The real composition build — the same call the TUI and the headless
        // runner make for their main conversation. The provider comes from the
        // composition (it may be wrapped, e.g. metering); the scripted driver
        // receives it verbatim.
        final provider = comp.buildStartupProvider();
        final driver = buildAgent(
          pipeline: comp.pipeline,
          scheduler: comp.scheduler,
          conversationId: comp.initialConversationId,
          provider: provider,
          host: host,
          policy: comp.policy,
          config: comp.config,
          withSubAgents: false,
        ) as _ScriptedDriver_merged;

        // The composition consulted the wired factory: what came back is the
        // scripted driver itself, not an agent built behind its back.
        expect(factory.created, hasLength(1));
        expect(driver, same(factory.created.single));

        // Driver-only conversation: no Agent behind the driver at all.
        final conversation = Conversation(
          id: comp.initialConversationId,
          label: 'scripted',
          driver: driver,
          provider: provider,
          host: host,
          policy: comp.policy,
        );
        expect(conversation.hasAgent, isFalse);

        final executor = TurnExecutor(
          findConversation: (id) => id == conversation.id ? conversation : null,
        );
        addTearDown(executor.shutdown);
        executor.submit(conversation.id, 'hello');
        await executor.whenIdle(conversation.id);

        // The scripted driver's run() executed — non-zero custom-driver runs.
        expect(driver.runCount, 1);
        expect(driver.inputs, ['hello']);
        // The canned assistant reply landed in the conversation history.
        expect(
          conversation.history.last.content.whereType<TextBlock>().single.text,
          'canned reply',
        );
        // The built-in agent loop never sent a request — on any provider
        // instance the composition created.
        expect(_RecordingProvider.totalSends, 0);
      },
    );

    test(
      'SessionManager keeps the composed driver: a created conversation runs '
      'turns through it, not through a rebuilt adapter',
      () async {
        final factory = _ScriptedDriverFactory_merged();
        final comp = await _build_merged(factory);
        addTearDown(comp.dispose);

        _RecordingProvider.reset();
        final createdProviders = <LlmProvider>[];
        final initialHost = FakeHostInterface();
        addTearDown(initialHost.dispose);

        AgentDriver agentBuilder({
          required String conversationId,
          required LlmProvider provider,
          required HostInterface host,
          required PermissionPolicy policy,
        }) => buildAgent(
          pipeline: comp.pipeline,
          scheduler: comp.scheduler,
          conversationId: conversationId,
          provider: provider,
          host: host,
          policy: policy,
          config: comp.config,
          withSubAgents: false,
        );

        final initialProvider = comp.buildStartupProvider();
        final initial = Conversation(
          id: 'root',
          label: 'root',
          driver: agentBuilder(
            conversationId: 'root',
            provider: initialProvider,
            host: initialHost,
            policy: comp.policy,
          ),
          provider: initialProvider,
          host: initialHost,
          policy: comp.policy,
        );

        final manager = SessionManager(
          initialConversation: initial,
          initialProviderId: 'test',
          initialApiKey: 'k',
          providerFactory: (pid, key, model, baseUrl) {
            final provider = _RecordingProvider(model);
            createdProviders.add(provider);
            return provider;
          },
          hostFactory: ({required conversationId, required isActive}) =>
              FakeHostInterface(),
          agentBuilder: agentBuilder,
        );
        addTearDown(manager.closeAll);

        final conversation = await manager.createConversation();
        expect(factory.created, hasLength(2));
        // The composed driver IS the conversation's driver — not a fresh
        // adapter wrapped around the bare agent.
        final driver = conversation.driver as _ScriptedDriver_merged;
        expect(driver, same(factory.created.last));

        final executor = TurnExecutor(
          findConversation: (id) => id == conversation.id ? conversation : null,
        );
        addTearDown(executor.shutdown);
        executor.submit(conversation.id, 'hello');
        await executor.whenIdle(conversation.id);

        expect(driver.runCount, 1);
        expect(driver.inputs, ['hello']);
        // No agent loop ran on any provider the manager built.
        expect(_RecordingProvider.totalSends, 0);
        expect(createdProviders, isNotEmpty);
      },
    );
  });
}

/// Minimal usage-reporting provider so the runtime (and its classifier probe)
/// can build a provider without any real backend.
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

class ProbeFactory implements AgentDriverFactory {
  late AgentDriverRequest request;
  @override
  AgentDriver create(AgentDriverRequest request) {
    this.request = request;
    return const DefaultAgentDriverFactory().create(request);
  }
}

class Provider extends LlmProvider {
  Provider() : super('test');
  int calls = 0;
  final advertised = <String>[];
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    advertised.addAll(tools.map((t) => t.name));
    if (calls++ == 0) {
      yield const MessageComplete(
        content: [
          ToolUseBlock(
            id: 'bad',
            name: 'bash',
            input: {'command': 'touch file'},
          ),
        ],
        stopReason: 'tool_use',
      );
    } else {
      yield const MessageComplete(
        content: [TextBlock('done')],
        stopReason: 'end_turn',
      );
    }
  }
}

class ProbeTool implements Tool {
  int calls = 0;
  @override
  ToolSchema get schema =>
      const ToolSchema(name: 'bash', description: 'probe', inputSchema: {});
  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    calls++;
    return const ToolResult('executed');
  }
}

ProviderRegistry _registryWithRecordingProvider() {
  final registry = ProviderRegistry(env: const {})
    ..register(
      ProviderDescriptor(
        id: 'test',
        name: 'Test',
        authSources: const [],
        defaultBaseUrl: 'https://example.test',
        builder: (c) => _RecordingProvider(c.model),
      ),
    );
  return registry;
}

/// A provider that records every `send`. The real agent loop is the only
/// thing that calls `send`, so a zero count after a turn proves the built-in
/// agent never executed — the scripted driver did the work. The composition
/// may wrap instances (metering), so tests assert across every instance
/// created rather than on one identity.
class _RecordingProvider extends LlmProvider {
  _RecordingProvider([super.model = 'a']) {
    created.add(this);
  }

  /// Every instance the test registry's builder minted.
  static final List<_RecordingProvider> created = [];

  static int get totalSends =>
      created.fold(0, (sum, p) => sum + p.sendCount);

  static void reset() => created.clear();

  int sendCount = 0;

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    sendCount++;
    return const Stream.empty();
  }
}

/// An agent-less scripted driver: it implements the [AgentDriver] contract
/// and NOTHING else. There is no [Agent] behind it to fall back on, so if
/// anything reaches past the driver for an agent it fails loudly instead of
/// silently running the built-in loop.
class _ScriptedDriver_merged implements AgentDriver {
  _ScriptedDriver_merged(this.provider);

  @override
  LlmProvider provider;

  int runCount = 0;
  final inputs = <String>[];

  @override
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
    HistoryAppendObserver? onHistoryAppend,
    HistoryReplaceObserver? onHistoryReplace,
  }) async {
    runCount++;
    inputs.add(userInput);
    history.add(
      const Message(role: Role.assistant, content: [TextBlock('canned reply')]),
    );
  }

  @override
  String? get abortedReason => null;

  @override
  AbortedKind get abortedKind => AbortedKind.none;

  @override
  String get system => 'scripted';

  @override
  ToolRegistry get tools => ToolRegistry(const []);

  @override
  Future<bool> compact(
    List<Message> history, {
    int preserveRecent = 0,
    int preserveRecentMessages = 0,
    Future<void>? cancelSignal,
  }) async => false;
}

class _ScriptedDriverFactory_merged implements AgentDriverFactory {
  /// Every driver the composition built (one per buildAgent call).
  final List<_ScriptedDriver_merged> created = [];

  @override
  AgentDriver create(AgentDriverRequest request) {
    final driver = _ScriptedDriver_merged(request.provider);
    created.add(driver);
    return driver;
  }
}

Future<AppComposition> _build_merged(_ScriptedDriverFactory_merged factory) =>
    buildAppComposition(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registryWithRecordingProvider(),
      store: MemorySessionStore(),
      environment: FakeEnvironment(),
      driverFactory: factory,
    );
