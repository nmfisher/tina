import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';
import '../helpers/memory_session_store.dart';

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
