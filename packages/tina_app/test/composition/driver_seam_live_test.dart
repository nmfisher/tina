import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/memory_session_store.dart';

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
class _ScriptedDriver implements AgentDriver {
  _ScriptedDriver(this.provider);

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

class _ScriptedDriverFactory implements AgentDriverFactory {
  /// Every driver the composition built (one per buildAgent call).
  final List<_ScriptedDriver> created = [];

  @override
  AgentDriver create(AgentDriverRequest request) {
    final driver = _ScriptedDriver(request.provider);
    created.add(driver);
    return driver;
  }
}

Future<AppComposition> _build(_ScriptedDriverFactory factory) =>
    buildAppComposition(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registryWithRecordingProvider(),
      store: MemorySessionStore(),
      environment: FakeEnvironment(),
      driverFactory: factory,
    );

void main() {
  test(
    'the composed driver runs the turn; the built-in agent never does '
    '(driver-only conversation)',
    () async {
      _RecordingProvider.reset();
      final factory = _ScriptedDriverFactory();
      final comp = await _build(factory);
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
      ) as _ScriptedDriver;

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
      final factory = _ScriptedDriverFactory();
      final comp = await _build(factory);
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
      final driver = conversation.driver as _ScriptedDriver;
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
}
