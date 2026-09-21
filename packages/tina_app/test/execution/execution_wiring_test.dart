import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import 'dart:async';
import 'dart:io';
import 'package:tina_app/tina_app.dart';

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

  @override
  PermissionPolicy get policy => PermissionPolicy();
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
  group('project background jobs', () {
    late FakeHostInterface host;
    late FakeProvider provider;
    late Conversation conv;

    setUp(() {
      host = FakeHostInterface();
      provider = FakeProvider(const []);
      conv = Conversation(
        id: 'c1',
        label: 'main',
        agent: Agent(
          provider: provider,
          tools: ToolRegistry(const []),
          sink: FakeAgentSink(),
          policy: PermissionPolicy(),
          asker: (_) async => PermissionResponse.denyOnce,
          system: '',
        ),
        provider: provider,
        host: host,
        policy: PermissionPolicy(),
      );
    });

    test('runIndex threads modelRefOf(conv) into the summary refresh',
        () async {
      String? lastModelRef;
      final idx = _StubSummaryIndex(onRefresh: (modelRef) {
        lastModelRef = modelRef;
        return const SummaryIndexResult(
          status: SummaryIndexStatus(
            totalDirs: 1,
            staleDirs: [],
            deletedDirs: [],
            headSha: 'zzz9998',
            firstRun: false,
            hasAllocations: false,
          ),
          regenerated: 1,
          regeneratedDirs: ['lib'],
          deletedDirs: [],
        );
      });
      final jobs = ProjectBackgroundJobs(
        supervisor: BackgroundJobSupervisor(),
        summaryIndex: () => idx,
        persistUsage: (_) async {},
        modelRefOf: (conv) => 'nim/existing-model',
      );

      await jobs.runIndex(conv, null);

      // The job is async; wait for the supervisor slot to drain.
      while (jobs.isIndexRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(idx.refreshCalls, 1);
      expect(lastModelRef, 'nim/existing-model');
    });
  });
  group('turn persistence', () {
    for (final shutdown in [false, true]) {
      test(
        'tool progress survives ${shutdown ? 'shutdown' : 'cancel'} during approval',
        () async {
          final dir = await Directory.systemTemp.createTemp('turn-persistence-');
          addTearDown(() => dir.delete(recursive: true));
          final store = JsonlSessionStore(Directory('${dir.path}/sessions'));
          final sid = await store.createSession(
            providerId: 'fake',
            cwd: dir.path,
          );
          final cid = await store.createConversation(sid);
          final recorder = SessionRecorder(store, sid, cid, providerId: 'fake')
            ..attach(sid, cid);
          final host = FakeHostInterface();
          final tool = _WriteTool(File('${dir.path}/effect'));
          final provider = FakeProvider([
            [
              MessageComplete(
                content: [
                  for (var i = 0; i < 3; i++)
                    ToolUseBlock(id: 'call$i', name: 'write_probe', input: {}),
                ],
                stopReason: 'tool_use',
              ),
            ],
          ]);
          final thirdApproval = Completer<void>();
          final abandonedApproval = Completer<PermissionResponse>();
          var approvals = 0;
          final policy = PermissionPolicy();
          final conversation = Conversation(
            id: cid,
            label: 'test',
            provider: provider,
            host: host,
            policy: policy,
            recorder: recorder,
            agent: Agent(
              provider: provider,
              tools: ToolRegistry([tool]),
              sink: host,
              policy: policy,
              system: '',
              asker: (prompt) async {
                approvals++;
                if (approvals < 3) return PermissionResponse.allowOnce;
                thirdApproval.complete();
                // An uncooperative/custom UI must not strand shutdown.
                return abandonedApproval.future;
              },
            ),
          );
          final turns = TurnExecutor(findConversation: (_) => conversation);
          turns.submit(cid, 'perform three writes');
          await thirdApproval.future.timeout(const Duration(seconds: 3));

          // Read using a fresh store WHILE the turn is blocked: no final flush,
          // graceful shutdown, or in-memory fake can hide lost incremental writes.
          final freshStore = JsonlSessionStore(store.root);
          final checkpoint = await freshStore.loadConversation(sid, cid);
          final results = checkpoint
              .expand((m) => m.content)
              .whereType<ToolResultBlock>()
              .toList();
          expect(results.map((r) => r.content), [
            'saved effect 1',
            'saved effect 2',
          ]);
          expect(tool.executions, 2);
          expect(await tool.file.readAsString(), 'effect 2');
          expect(
            checkpoint.where(
              (m) => m.role == Role.user && m.content.any((b) => b is TextBlock),
            ),
            hasLength(1),
          );

          // A hard-kill restore with a missing result is safe to send again and
          // does not claim the unfinished call never executed.
          expect(recoverInterruptedToolCalls(checkpoint), isTrue);
          final unknown = checkpoint.last.content.last as ToolResultBlock;
          expect(unknown.toolUseId, 'call2');
          expect(unknown.content, contains('status is unknown'));
          expect(recoverInterruptedToolCalls(checkpoint), isFalse);

          if (shutdown) {
            await turns.shutdown().timeout(const Duration(seconds: 3));
          } else {
            turns.cancel(cid);
            await turns.whenIdle(cid).timeout(const Duration(seconds: 3));
          }
          final restored = await freshStore.loadConversation(sid, cid);
          expect(
            restored.expand((m) => m.content).whereType<ToolResultBlock>(),
            hasLength(3),
          );
          expect(restored.last.content.single.toJson()['text'], '[cancelled]');
          expect(tool.executions, 2);
          // A late approval cannot execute, remember a grant, or affect a new turn.
          abandonedApproval.complete(PermissionResponse.allowAlways);
          await Future<void>.delayed(Duration.zero);
          expect(policy.sessionRules, isEmpty);
          expect(tool.executions, 2);
          expect(
            conversation.history.map((m) => m.toJson()),
            restored.map((m) => m.toJson()),
          );
        },
      );
    }
  });
}

/// The background /index fleet must run on the conversation's PROVEN model
/// ref (persisted meta, else the session provider + live model) — never the
/// config default, which can name a model the provider cannot serve (every
/// request then 404s and the run dies as unfinished nodes).

class _StubSummaryIndex implements SummaryIndex {
  _StubSummaryIndex({required this.onRefresh});

  final SummaryIndexResult Function(String? modelRef) onRefresh;
  int refreshCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<SummaryIndexResult> refresh({
    bool repartition = false,
    bool dryRun = false,
    List<String>? dirs,
    HostInterface? host,
    String? modelRef,
    Future<void>? cancelSignal,
  }) async {
    refreshCalls++;
    return onRefresh(modelRef);
  }
}

class _WriteTool extends Tool {
  final File file;
  int executions = 0;
  _WriteTool(this.file);
  @override
  ToolSchema get schema => const ToolSchema(
    name: 'write_probe',
    description: 'write a marker',
    inputSchema: {'type': 'object'},
  );
  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    executions++;
    await file.writeAsString('effect $executions');
    return ToolResult('saved effect $executions');
  }
}
