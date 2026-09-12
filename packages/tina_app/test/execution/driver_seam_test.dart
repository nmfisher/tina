import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/src/execution/turn_executor.dart';
import 'package:tina_app/src/session/conversation.dart';
import 'package:tina_app/src/session/session_manager.dart';
import '../helpers/fake_host_interface.dart';

/// A provider that records every `send` — the proof that the real agent loop
/// (the only thing that calls `send`) never ran when a scripted driver is in
/// place — and reports `close` so provider-swap behavior stays observable.
class _RecordingProvider extends LlmProvider {
  _RecordingProvider([super.model = 'fake']);

  int sendCount = 0;
  bool closed = false;

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    sendCount++;
    return const Stream.empty();
  }

  @override
  void close() {
    closed = true;
  }
}

/// A driver that scripts the whole turn loop: `run` records the input and
/// appends a canned assistant message; `compact` records its arguments and
/// rewrites history with a summary. Nothing reaches the wrapped agent.
class _ScriptedDriver implements AgentDriver {
  _ScriptedDriver(this.agent);

  /// The agent this driver must drive (same history/provider surface). Never
  /// invoked by the script — held so the pairing contract is expressible.
  final Agent agent;

  final inputs = <String>[];
  int runCount = 0;
  int compactCalls = 0;
  int? lastCompactPreserveRecent;
  Future<void>? lastCompactCancelSignal;
  bool compactResult = true;

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
  String get system => agent.system;

  @override
  ToolRegistry get tools => agent.tools;

  @override
  LlmProvider get provider => agent.provider;

  @override
  set provider(LlmProvider value) => agent.provider = value;

  @override
  Future<bool> compact(
    List<Message> history, {
    int preserveRecent = 0,
    int preserveRecentMessages = 0,
    Future<void>? cancelSignal,
  }) async {
    compactCalls++;
    lastCompactPreserveRecent = preserveRecent;
    lastCompactCancelSignal = cancelSignal;
    if (!compactResult) return false;
    final kept = preserveRecent > 0 && history.length > preserveRecent
        ? history.sublist(history.length - preserveRecent)
        : const <Message>[];
    history
      ..clear()
      ..addAll([
        const Message(role: Role.user, content: [TextBlock('summary')]),
        ...kept,
      ]);
    return true;
  }
}

Agent _agentFor(LlmProvider provider, HostInterface host) => Agent(
  provider: provider,
  tools: ToolRegistry(const []),
  sink: host,
  policy: PermissionPolicy(),
  asker: host.askPermission,
  system: '',
);

Conversation _conversation(
  String id,
  _RecordingProvider provider,
  FakeHostInterface host, {
  AgentDriver? driver,
}) {
  final agent = _agentFor(provider, host);
  return Conversation(
    id: id,
    label: id,
    agent: agent,
    provider: provider,
    host: host,
    policy: PermissionPolicy(),
    driver: driver,
  );
}

void main() {
  test('agent-only construction wires an adapter around THAT agent; '
      'replaceProvider still swaps the agent provider', () async {
    final providerA = _RecordingProvider('a');
    final host = FakeHostInterface();
    final conversation = _conversation('c1', providerA, host);
    final agent = conversation.agent;

    // Default driver: an adapter wrapping the very same agent instance.
    expect(conversation.driver, isA<AgentDriverAdapter>());
    final adapter = conversation.driver as AgentDriverAdapter;
    expect(identical(adapter.agent, agent), isTrue);
    // The adapter surface agrees with the agent it wraps.
    expect(identical(conversation.driver.tools, agent.tools), isTrue);
    expect(conversation.driver.system, agent.system);
    expect(identical(conversation.driver.provider, providerA), isTrue);

    // Replacement routes through the driver; the adapter forwards to the
    // agent, and the old provider is closed exactly as before.
    final providerB = _RecordingProvider('b');
    expect(conversation.replaceProvider(providerB), isNull);
    expect(conversation.provider, same(providerB));
    expect(conversation.agent.provider, same(providerB));
    expect(conversation.driver.provider, same(providerB));
    expect(providerA.closed, isTrue);
    expect(providerB.closed, isFalse);

    await host.dispose();
  });

  test('a custom driver replaces the default WITHOUT editing the coordinator: '
      'the scripted driver runs the turn, the agent is never called', () async {
    final initialProvider = _RecordingProvider('initial');
    final initialHost = FakeHostInterface();
    final initial = _conversation('root', initialProvider, initialHost);

    final wrappedAgents = <Agent>[];
    late final _ScriptedDriver scripted;
    final createdProviders = <_RecordingProvider>[];
    final manager = SessionManager(
      initialConversation: initial,
      initialProviderId: 'p',
      initialApiKey: 'k',
      providerFactory: (pid, key, model, baseUrl) {
        final provider = _RecordingProvider(model);
        createdProviders.add(provider);
        return provider;
      },
      hostFactory: ({required conversationId, required isActive}) =>
          FakeHostInterface(),
      agentBuilder:
          ({
            required conversationId,
            required provider,
            required host,
            required policy,
          }) => AgentDriverAdapter(_agentFor(provider, host)),
      driverWrapper: (agent) {
        wrappedAgents.add(agent);
        scripted = _ScriptedDriver(agent);
        return scripted;
      },
    );

    // Built through _buildConversation — the wrapper receives the built
    // agent and its result becomes the conversation's driver.
    final conversation = await manager.createConversation();
    expect(wrappedAgents, hasLength(1));
    expect(conversation.driver, same(scripted));
    expect(identical(scripted.agent, wrappedAgents.single), isTrue);
    // The scripted driver drives THE agent the manager built (its provider
    // is the one that factory built for this conversation).
    expect(createdProviders, hasLength(1));
    expect(scripted.agent.provider, same(createdProviders.single));

    final executor = TurnExecutor(
      findConversation: (id) => id == conversation.id ? conversation : null,
    );
    executor.submit(conversation.id, 'hello');
    await executor.whenIdle(conversation.id);

    // The scripted driver ran, with the submitted input.
    expect(scripted.runCount, 1);
    expect(scripted.inputs, ['hello']);
    // The agent was never called: its provider never saw a request.
    expect(createdProviders.single.sendCount, 0);
    // The canned assistant message landed in the conversation history.
    final assistants = conversation.history
        .where((m) => m.role == Role.assistant)
        .toList(growable: false);
    expect(assistants, hasLength(1));
    expect(
      assistants.single.content.whereType<TextBlock>().single.text,
      'canned reply',
    );
    expect(executor.state(conversation.id), TurnState.idle);

    await executor.shutdown();
    await initialHost.dispose();
  });

  test(
    'compact goes through the driver: the scripted compact is consulted',
    () async {
      final provider = _RecordingProvider('p');
      final host = FakeHostInterface();
      final scripted = _ScriptedDriver(_agentFor(provider, host));
      final conversation = _conversation(
        'c3',
        provider,
        host,
        driver: scripted,
      );
      const oldText = 'x x x x x x x x x x old history';
      conversation.history.add(
        const Message(role: Role.user, content: [TextBlock(oldText)]),
      );

      final executor = TurnExecutor(
        findConversation: (_) => conversation,
        autoCompactThreshold: 1,
        autoCompactPreserveRecent: 0,
      );
      executor.submit(conversation.id, 'new');
      await executor.whenIdle(conversation.id);

      // The executor's compaction path consulted the DRIVER, not the agent.
      expect(scripted.compactCalls, 1);
      expect(scripted.lastCompactPreserveRecent, 0);
      expect(scripted.lastCompactCancelSignal, isNotNull);
      // The scripted compact rewrote history: the old content is gone and the
      // summary took its place.
      expect(
        conversation.history.any(
          (m) => m.content.whereType<TextBlock>().any((b) => b.text == oldText),
        ),
        isFalse,
      );
      expect(
        conversation.history.first.content.whereType<TextBlock>().single.text,
        'summary',
      );
      // The executor surfaced the compaction, then the scripted run completed
      // the turn — still without ever reaching the agent.
      expect(
        host.messages.where((m) => m.contains('auto-compacted')),
        isNotEmpty,
      );
      expect(scripted.inputs, ['new']);
      expect(provider.sendCount, 0);

      await executor.shutdown();
      await host.dispose();
    },
  );
}
