import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

/// A provider that records each turn's user-task text into a shared [sink] and
/// answers [_answers.first]. Built fresh per job by a registry builder that
/// closes over the same [sink]/[_answers], so a multi-stage workflow (which
/// builds one provider per stage) shares the recorder across stages — used to
/// assert handoff context flows from stage to stage.
class _RecordingProvider extends LlmProvider {
  final List<String> _answers;
  final List<String> _sink;
  _RecordingProvider(this._answers, this._sink) : super('rec');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    final taskText =
        messages.last.content.whereType<TextBlock>().map((b) => b.text).join();
    _sink.add(taskText);
    final answer = _answers.first;
    return Stream.fromIterable([
      TextDelta(answer),
      MessageComplete(content: [TextBlock(answer)], stopReason: 'end_turn'),
    ]);
  }
}

/// A provider that records the `system` prompt it receives each turn, for
/// asserting a sub-agent's prompt reaches the provider.
class _SystemCapturingProvider extends LlmProvider {
  final List<String> seen;
  final List<StreamEvent> answer;
  _SystemCapturingProvider(this.seen, this.answer) : super('cap-sys');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    seen.add(system);
    return Stream.fromIterable(answer);
  }
}

/// A provider that never stops issuing tool calls — turn 1 also carries a text
/// preamble. Drives a leaf into its step ceiling so we can assert the scheduler
/// reports the non-finish honestly instead of scavenging the preamble as though
/// it were the "final answer".
class _LoopingToolProvider extends LlmProvider {
  int _calls = 0;
  _LoopingToolProvider() : super('loop');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    _calls++;
    final content = _calls == 1
        ? <ContentBlock>[
            const TextBlock('preliminary fragment'),
            const ToolUseBlock(id: 't', name: 'read', input: {}),
          ]
        : <ContentBlock>[const ToolUseBlock(id: 't', name: 'read', input: {})];
    return Stream.fromIterable([
      MessageComplete(content: content, stopReason: 'tool_use'),
    ]);
  }
}

/// A no-op [SessionStore] — the panelization path under test only needs a
/// recorder handle, not real persistence.
class _FakeStore implements SessionStore {
  @override
  Future<String> createSession(
          {required String providerId, String? baseUrl, String? cwd}) async =>
      's';
  @override
  Future<String> createConversation(String sessionId, {String? model}) async =>
      'c';
  @override
  Future<String> createConversationWithMeta(
          String sessionId, ConversationMetaInput input) async =>
      'c';
  @override
  Future<void> append(
      String sessionId, String conversationId, Message message) async {}
  @override
  Future<void> replace(
      String sessionId, String conversationId, List<Message> messages) async {}
  @override
  Future<List<Message>> loadConversation(
          String sessionId, String conversationId) async =>
      const [];
  @override
  Future<SessionManifest> loadSession(String sessionId) async =>
      SessionManifest(
        id: '',
        providerId: '',
        activeConversationId: '',
        conversations: const [],
      );
  @override
  Future<void> setActiveConversation(
      String sessionId, String conversationId) async {}
  @override
  Future<List<SessionMeta>> listSessions() async => const [];
  @override
  Future<void> deleteSession(String sessionId) async {}
  @override
  Future<void> deleteConversation(
      String sessionId, String conversationId) async {}
  @override
  Future<void> close() async {}
}

void main() {
  final pipeline = defaultTestPipeline();
  group('model tiers', () {
    test('a role.modelTier resolves through the scheduler tier map', () async {
      final scheduler = testScheduler(
        scriptedRegistry(
            {'a': answerEvents('from-a'), 'b': answerEvents('from-b')}),
        pipeline: pipeline,
        // tier 'heavy' → provider b; overrides the inherited a/a-model.
        modelTiers: {'heavy': 'b/b-model'},
      );
      final job = scheduler.spawn(
        target:
            const AgentRole(name: 'b', description: 'b', modelTier: 'heavy'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(result.content, 'from-b');
      await scheduler.dispose();
    });

    test('an unmapped tier errors rather than silently inheriting', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('from-a')}),
        pipeline: pipeline,
        modelTiers: const {},
      );
      final job = scheduler.spawn(
        target:
            const AgentRole(name: 'a', description: 'a', modelTier: 'ghost'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isTrue);
      expect(result.content, contains('unknown model tier'));
      await scheduler.dispose();
    });

    test('a null tier inherits the parent reference', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('from-a')}),
        pipeline: pipeline,
      );
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(result.content, 'from-a');
      await scheduler.dispose();
    });
  });

  group('live panelization (panelSink)', () {
    test('a first-class (factory) job becomes a session + wires focus',
        () async {
      // Mirrors the coordinator's Phase 3 wiring: persistence stashes the panel
      // host + a focus-wiring callback on the job, and subAgentSessionFactory is
      // set. Assert the factory is invoked, gets the host, returns an Agent,
      // and wires a non-null focus handler — i.e. focusing the panel would make
      // it the active session.
      final wiredFocus = <void Function()>[];
      final providerAskerCalls = <String>[];
      final host = FakeHostInterface();
      final store = _FakeStore();
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('from-a')}),
        pipeline: pipeline,
      );
      scheduler.persistence =
          (job, {required meta, required parentConversationId}) async {
        final conv = await store.createConversationWithMeta('s', meta);
        job.panelSink = FakeAgentSink();
        job.panelHost = host;
        job.wirePanelFocus = wiredFocus.add;
        final recorder = SessionRecorder(store, 's', conv, providerId: 'a');
        recorder.attach('s', conv);
        return (conv, recorder);
      };
      Agent? capturedAgent;
      scheduler.subAgentSessionFactory = (scheduler, job,
          {required provider,
          required tools,
          required policy,
          required sink,
          required host,
          required recorder,
          required conversationId,
          required label,
          system,
          maxSteps,
          budget,
          pauseGate,
          required wirePanelFocus}) {
        // The factory received the panel host (the active-session asker source).
        capturedAgent = Agent(
          provider: provider,
          tools: tools,
          sink: sink,
          policy: policy,
          asker: host.askPermission,
          maxSteps: maxSteps ?? 25,
          system: system ?? '',
        );
        wirePanelFocus(() => providerAskerCalls.add('focus'));
        return capturedAgent!;
      };
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(capturedAgent, isNotNull, reason: 'factory was invoked');
      // The factory wired a focus handler through the stashed callback.
      expect(wiredFocus, hasLength(1));
      expect(providerAskerCalls, isEmpty);
      wiredFocus.first(); // invoke the wired handler
      expect(providerAskerCalls, ['focus']);
      // Panel host + recorder were supplied to the factory (host is the panel).
      expect(job.panelHost, same(host));
      expect(job.recorder, isNotNull);
      await scheduler.dispose();
    });

    test('a job panelized by persistence streams into its panel sink',
        () async {
      // Mirrors the coordinator's scheduler.persistence hook: persist a
      // conversation, then stash a panel sink on the job. Assert _runAgent uses
      // that sink (the sub-agent's prose lands in it) instead of defaulting to
      // the telemetry-only SubAgentSink.
      final sink = <String>[];
      final store = _FakeStore();
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('from-a')}),
        pipeline: pipeline,
      );
      scheduler.persistence =
          (job, {required meta, required parentConversationId}) async {
        final conv = await store.createConversationWithMeta('s', meta);
        job.panelSink = FakeAgentSink(texts: sink);
        final recorder = SessionRecorder(store, 's', conv, providerId: 'a');
        recorder.attach('s', conv);
        return (conv, recorder);
      };
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      // The panel sink was wired and received the streamed prose.
      expect(sink, isNotEmpty);
      expect(sink.join(), contains('from-a'));
      // A non-panelized job would fall back to SubAgentSink (no sink set).
      await scheduler.dispose();
    });

    test('with no persistence the job streams into the parent chat (fallback)',
        () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('from-a')}),
        pipeline: pipeline,
      );
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(result.content, 'from-a');
      // persistence unwired → no panel sink (telemetry-only path).
      expect(job.panelSink, isNull);
      await scheduler.dispose();
    });
  });

  group('sub-agent budget', () {
    /// A final-answer turn that also reports [tokens] in+out, so a tight
    /// per-session budget trips on the first (and only) provider call.
    List<StreamEvent> _answerWithUsage(String text, int tokens) => [
          TextDelta(text),
          MessageComplete(
            content: [TextBlock(text)],
            stopReason: 'end_turn',
            usage: TokenUsage(inputTokens: tokens, outputTokens: tokens),
          ),
        ];

    test('a tight subAgentBudgetLimit aborts the sub-agent', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': _answerWithUsage('done', 60)}),
        pipeline: pipeline,
        subAgentBudgetLimit: 100, // 120 reported > 100 → trip on first call
      );
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isTrue,
          reason: 'the per-session budget should abort the sub-agent before it '
              'finishes');
      await scheduler.dispose();
    });

    test('subAgentBudgetLimit 0 (default) leaves the sub-agent uncapped',
        () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': _answerWithUsage('done', 60)}),
        pipeline: pipeline,
        // subAgentBudgetLimit defaults to 0.
      );
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(result.content, 'done');
      await scheduler.dispose();
    });

    test('a sub-agent per-session trip fires the shared pause gate', () async {
      final gate = PauseGate();
      var paused = 0;
      final sub = gate.onPause.listen((_) {
        paused++;
        gate.resume(continueDecision: false); // abort so the job ends
      });
      final scheduler = testScheduler(
        scriptedRegistry({'a': _answerWithUsage('done', 60)}),
        pipeline: pipeline,
        subAgentBudgetLimit: 100, // 120 > 100 → trip
        pauseGate: gate,
      );
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a'),
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(paused, 1, reason: 'the sub-agent trip fired the shared gate');
      expect(result.isError, isTrue, reason: 'abort ended the sub-agent turn');
      await sub.cancel();
      await gate.dispose();
      await scheduler.dispose();
    });
  });

  test('a one-step subagent returns its final answer', () async {
    final scheduler = testScheduler(
      scriptedRegistry({'a': answerEvents('hello')}),
      pipeline: pipeline,
      modelTiers: defaultTestTiersExtended,
    );
    final job = scheduler.spawn(
      target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
      task: 'do it',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'conv1',
    );
    final result = await job.result;
    expect(result.isError, isFalse);
    expect(result.content, 'hello');
    expect(job.status, SubAgentJobStatus.done);
    await scheduler.dispose();
  });

  test('role.promptIdentity is honored; absence yields the wrapped default',
      () async {
    final seenSystems = <String>[];
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (_) =>
            _SystemCapturingProvider(seenSystems, answerEvents('ok')),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(
      r,
      pipeline: pipeline,
      modelTiers: defaultTestTiersExtended,
    );

    // A custom promptIdentity reaches the provider verbatim (wrapped).
    final withPrompt = scheduler.spawn(
      target: AgentRole(
        name: 'a',
        description: 'a',
        modelTier: 'a',
        promptIdentity: 'CUSTOM-SYS',
      ),
      task: 'do it',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'conv1',
    );
    expect((await withPrompt.result).isError, isFalse);
    expect(seenSystems.any((s) => s.contains('CUSTOM-SYS')), isTrue);

    // Empty promptIdentity → the environment wrapper is still applied.
    final withoutPrompt = scheduler.spawn(
      target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
      task: 'again',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'conv1',
    );
    expect((await withoutPrompt.result).isError, isFalse);
    expect(seenSystems.any((s) => s.contains('<environment>')), isTrue);

    await scheduler.dispose();
  });

  test(
      'a leaf that hits its step ceiling reports a non-finish, not a scavenged '
      'preamble', () async {
    // Turn 1 carries a text preamble AND a tool call, then the provider keeps
    // tool-calling forever. The old `_extractResult` walked backwards and
    // returned 'preliminary fragment' as the final answer of a job that had in
    // fact run out of steps. The fix reports the non-finish honestly.
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (_) => _LoopingToolProvider(),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(
      r,
      pipeline: pipeline,
      modelTiers: defaultTestTiersExtended,
    );
    final job = scheduler.spawn(
      target: AgentRole(
          name: 'a',
          description: 'a',
          modelTier: 'a',
          maxSteps: 3,
          tools: {FakeTool.noOp('read')}),
      task: 'do it',
      parentReference: 'a/a-model',
      parentPolicy:
          PermissionPolicy(defaults: {'read': PermissionDecision.allow}),
      originConversationId: 'conv1',
    );
    final result = await job.result;
    expect(result.isError, isTrue);
    expect(result.content, contains('did not finish'));
    expect(result.content, isNot(contains('preliminary fragment')));
    expect(job.status, SubAgentJobStatus.errored);
    await scheduler.dispose();
  });

  test('a different model tier builds that provider (cross-tier)', () async {
    final scheduler = testScheduler(
      scriptedRegistry({
        'a': answerEvents('from-a'),
        'b': answerEvents('from-b'),
      }),
      pipeline: pipeline,
      modelTiers: defaultTestTiersExtended,
    );

    // Parent is 'a'; role pins tier 'b' → runs on b, returns from-b.
    final cross = scheduler.spawn(
      target: const AgentRole(name: 'b', description: 'b', modelTier: 'b'),
      task: 'x',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'conv1',
    );
    expect((await cross.result).content, 'from-b');

    // modelTier null inherits the parent (a) → from-a.
    final inherit = scheduler.spawn(
      target: const AgentRole(name: 'a', description: 'a'),
      task: 'x',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'conv1',
    );
    expect((await inherit.result).content, 'from-a');
    await scheduler.dispose();
  });

  test('a tool the role did not declare is denied with no toolStart event',
      () async {
    // Script: first call asks for bash; second call answers after the denial.
    final bashThenDone = <List<StreamEvent>>[
      [
        const ToolCallStart(id: 'c1', name: 'bash'),
        const MessageComplete(
          content: [
            ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'ls'})
          ],
          stopReason: 'tool_use',
        ),
      ],
      [
        const TextDelta('done'),
        const MessageComplete(
            content: [TextBlock('done')], stopReason: 'end_turn'),
      ],
    ];
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => FakeProvider(bashThenDone, model: c.model),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(
      r,
      pipeline: pipeline,
      modelTiers: defaultTestTiersExtended,
    );

    final seen = <AgentEvent>[];
    final sub = scheduler.events.listen(seen.add);

    // The role declares `read` only — `bash` is outside its set, so the derived
    // policy denies it (ask → auto-deny) before any toolStart.
    final job = scheduler.spawn(
      target: AgentRole(
          name: 'a',
          description: 'a',
          modelTier: 'a',
          tools: {FakeTool.noOp('read')}),
      task: 'run ls',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'conv1',
    );
    final result = await job.result;
    await Future<void>.delayed(Duration.zero);
    sub.cancel();

    expect(result.content, 'done');
    // No bash tool *start* reached the bus (deny short-circuits before it).
    final bashStarts = seen.whereType<JobAgentEvent>().where((e) {
      final inner = e.event;
      return inner is ToolAgentEvent &&
          inner.event is ToolStartEvent &&
          (inner.event as ToolStartEvent).toolName == 'bash';
    });
    expect(bashStarts, isEmpty);
    await scheduler.dispose();
  });

  test('maxConcurrent caps live jobs; extras queue', () async {
    final gate = Completer<void>();
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => HoldProvider(
          gate: gate.future,
          releaseEvents: const [
            TextDelta('released'),
            MessageComplete(
              content: [TextBlock('released')],
              stopReason: 'end_turn',
            ),
          ],
        ),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(
      r,
      pipeline: pipeline,
      maxConcurrent: 1,
      modelTiers: defaultTestTiersExtended,
    );

    final j1 = scheduler.spawn(
      target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
      task: 'hold',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'c1',
    );
    final j2 = scheduler.spawn(
      target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
      task: 'hold',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'c1',
    );

    // Let the first job acquire the slot and start; the second queues.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(j1.status, SubAgentJobStatus.running);
    expect(j2.status, SubAgentJobStatus.queued);

    gate.complete();
    await j1.result;
    await j2.result;
    expect(j1.status, SubAgentJobStatus.done);
    expect(j2.status, SubAgentJobStatus.done);
    await scheduler.dispose();
  });

  test('depth cap is enforced in spawn() even without the delegate tool',
      () async {
    // maxDepth 1: a spawn at depth 1 must be rejected at the chokepoint, not
    // merely by withholding the nested delegate tool (which an agent that
    // already holds the tool, or a workflow stage, would otherwise ignore).
    final scheduler = testScheduler(
      scriptedRegistry({'a': answerEvents('from-a')}),
      pipeline: pipeline,
      quota: AgentQuota(maxDepth: 1),
      modelTiers: defaultTestTiersExtended,
    );
    final job = scheduler.spawn(
      target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
      task: 'do it',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'c1',
      depth: 1, // == maxDepth → spawn() rejects
    );
    final result = await job.result.timeout(const Duration(seconds: 10));
    expect(result.isError, isTrue);
    expect(result.content, contains('max nesting depth'));
    await scheduler.dispose();
  });

  test('a shared AgentQuota caps live agents across schedulers', () async {
    final gate = Completer<void>();
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => HoldProvider(
          gate: gate.future,
          releaseEvents: const [
            TextDelta('released'),
            MessageComplete(
              content: [TextBlock('released')],
              stopReason: 'end_turn',
            ),
          ],
        ),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    // One quota shared by two schedulers → one global live cap.
    final quota = AgentQuota(maxLive: 2);
    final s1 = testScheduler(
      r,
      pipeline: pipeline,
      quota: quota,
      modelTiers: defaultTestTiersExtended,
    );
    final s2 = testScheduler(
      r,
      pipeline: pipeline,
      quota: quota,
      modelTiers: defaultTestTiersExtended,
    );

    // Three spawns split across two schedulers; only two live slots exist.
    final jobs = [
      s1.spawn(
          target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
          task: 'h',
          parentReference: 'a/a-model',
          parentPolicy: PermissionPolicy(),
          originConversationId: 'c1'),
      s2.spawn(
          target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
          task: 'h',
          parentReference: 'a/a-model',
          parentPolicy: PermissionPolicy(),
          originConversationId: 'c1'),
      s1.spawn(
          target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
          task: 'h',
          parentReference: 'a/a-model',
          parentPolicy: PermissionPolicy(),
          originConversationId: 'c1'),
    ];
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(jobs.where((j) => j.status == SubAgentJobStatus.running).length, 2,
        reason: 'global live cap is shared across both schedulers');
    expect(jobs.where((j) => j.status == SubAgentJobStatus.queued).length, 1);

    gate.complete();
    await Future.wait(jobs.map((j) => j.result));
    for (final j in jobs) expect(j.status, SubAgentJobStatus.done);
    await s1.dispose();
    await s2.dispose();
  });

  test('cancel() moves a running job to cancelled', () async {
    final gate = Completer<void>(); // never completed
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => HoldProvider(
          gate: gate.future,
          releaseEvents: const [
            TextDelta('released'),
            MessageComplete(
              content: [TextBlock('released')],
              stopReason: 'end_turn',
            ),
          ],
        ),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(
      r,
      pipeline: pipeline,
      modelTiers: defaultTestTiersExtended,
    );

    final job = scheduler.spawn(
      target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
      task: 'hold',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'c1',
    );
    await Future<void>.delayed(Duration.zero); // let it start
    await job.cancel();
    final result = await job.result.timeout(const Duration(seconds: 5));
    expect(job.status, SubAgentJobStatus.cancelled);
    expect(result.isError, isTrue);
    await scheduler.dispose();
  });

  test('cancelAll tears down every job', () async {
    final gate = Completer<void>(); // never completed
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => HoldProvider(
          gate: gate.future,
          releaseEvents: const [
            TextDelta('released'),
            MessageComplete(
              content: [TextBlock('released')],
              stopReason: 'end_turn',
            ),
          ],
        ),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(
      r,
      pipeline: pipeline,
      modelTiers: defaultTestTiersExtended,
    );
    final jobs = [
      for (var i = 0; i < 3; i++)
        scheduler.spawn(
          target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
          task: 'hold',
          parentReference: 'a/a-model',
          parentPolicy: PermissionPolicy(),
          originConversationId: 'c1',
        ),
    ];
    await Future<void>.delayed(Duration.zero);
    await scheduler.cancelAll();
    final results = await Future.wait(
        jobs.map((j) => j.result.timeout(const Duration(seconds: 5))));
    expect(results.every((r) => r.isError), isTrue);
    expect(jobs.every((j) => j.status == SubAgentJobStatus.cancelled), isTrue);
    await scheduler.dispose();
  });

  group('workflows', () {
    test('runs stages in order and returns the final stage output', () async {
      // Each stage pins a distinct provider so their answers differ.
      final implementer =
          AgentRole(name: 'implementer', description: 'd', modelTier: 'a');
      final verifier =
          AgentRole(name: 'verifier', description: 'd', modelTier: 'b');
      final tester =
          AgentRole(name: 'tester', description: 'd', modelTier: 'c');
      final qa = Workflow(
        name: 'qa',
        description: 'implement → verify → test',
        stages: [
          WorkflowStage(target: implementer, task: 'Implement.'),
          WorkflowStage(target: verifier, task: 'Review.'),
          WorkflowStage(target: tester, task: 'Test.'),
        ],
      );
      final qaPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [implementer, verifier, tester],
        workflows: [qa],
      );
      final scheduler = testScheduler(
        scriptedRegistry({
          'a': answerEvents('impl'),
          'b': answerEvents('verify'),
          'c': answerEvents('test'),
        }),
        pipeline: qaPipeline,
        modelTiers: defaultTestTiersExtended,
      );

      final job = scheduler.spawn(
        target: qa,
        task: 'build feature X',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      final result = await job.result.timeout(const Duration(seconds: 10));

      expect(job.status, SubAgentJobStatus.done);
      expect(result.isError, isFalse);
      // Final stage's output is the result — not the first stage's.
      expect(result.content, 'test');
      await scheduler.dispose();
    });

    test('each stage receives prior stages\' output as handoff context',
        () async {
      final received = <String>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'a',
          name: 'a',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://a.test',
          builder: (c) => _RecordingProvider(const ['impl-out'], received),
          models: const {
            'a-model': ModelInfo(
                id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final s1 = AgentRole(name: 's1', description: 'd', modelTier: 'a');
      final s2 = AgentRole(name: 's2', description: 'd', modelTier: 'a');
      final two = Workflow(
        name: 'two',
        description: 'two-stage',
        stages: [
          WorkflowStage(target: s1, task: 'STAGE ONE'),
          WorkflowStage(target: s2, task: 'STAGE TWO'),
        ],
      );
      final twoPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [s1, s2],
        workflows: [two],
      );
      final scheduler = testScheduler(
        r,
        pipeline: twoPipeline,
        modelTiers: defaultTestTiersExtended,
      );

      final job = scheduler.spawn(
        target: two,
        task: 'THE INPUT',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      await job.result.timeout(const Duration(seconds: 10));
      await scheduler.dispose();

      // Stage 1 sees the workflow's input; stage 2 sees stage 1's output.
      expect(received, hasLength(2));
      expect(received[0], contains('STAGE ONE'));
      expect(received[0], contains('THE INPUT'));
      expect(received[1], contains('STAGE TWO'));
      expect(received[1], contains('--- prior work ---'));
      expect(received[1], contains('impl-out'));
    });

    test('a haltOnFail stage error short-circuits the chain', () async {
      // Verifier pins an unregistered provider → build fails → error result.
      // With haltOnFail, the workflow stops there and the tester never runs.
      final received = <String>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'a',
          name: 'a',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://a.test',
          builder: (c) => _RecordingProvider(const ['impl-out'], received),
          models: const {
            'a-model': ModelInfo(
                id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final implementer =
          AgentRole(name: 'implementer', description: 'd', modelTier: 'a');
      final verifier = AgentRole(
          name: 'verifier',
          description: 'd',
          modelTier: 'x'); // unregistered → build fails
      final tester =
          AgentRole(name: 'tester', description: 'd', modelTier: 'a');
      final qa = Workflow(
        name: 'qa',
        description: 'halt at verifier',
        stages: [
          WorkflowStage(target: implementer, task: 'Implement.'),
          WorkflowStage(target: verifier, task: 'Review.', haltOnFail: true),
          WorkflowStage(target: tester, task: 'Test.'),
        ],
      );
      final haltPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [implementer, verifier, tester],
        workflows: [qa],
      );
      final scheduler = testScheduler(
        r,
        pipeline: haltPipeline,
        modelTiers: defaultTestTiersExtended,
      );

      final job = scheduler.spawn(
        target: qa,
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      final result = await job.result.timeout(const Duration(seconds: 10));
      await scheduler.dispose();

      expect(result.isError, isTrue);
      expect(result.content, contains('failed to build provider'));
      // Provider 'a' was called once (implementer only) — the tester never ran.
      expect(received, hasLength(1));
      expect(job.status, SubAgentJobStatus.errored);
    });

    test('an empty workflow yields an error', () async {
      final empty =
          Workflow(name: 'empty', description: 'no stages', stages: []);
      final emptyPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: const [],
        workflows: [empty],
      );
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('x')}),
        pipeline: emptyPipeline,
        modelTiers: defaultTestTiersExtended,
      );

      final job = scheduler.spawn(
        target: empty,
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      final result = await job.result.timeout(const Duration(seconds: 10));
      await scheduler.dispose();

      expect(result.isError, isTrue);
      expect(result.content, contains('no stages'));
    });

    test('a workflow beyond maxDepth errors instead of recursing', () async {
      final implementer =
          AgentRole(name: 'implementer', description: 'd', modelTier: 'a');
      final qa = Workflow(
          name: 'qa',
          description: 'workflow',
          stages: [WorkflowStage(target: implementer, task: 'go')]);
      final depthPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [implementer],
        workflows: [qa],
      );
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('x')}),
        pipeline: depthPipeline,
        maxDepth: 1,
        modelTiers: defaultTestTiersExtended,
      );

      final job = scheduler.spawn(
        target: qa,
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
        depth: 1, // == maxDepth → workflow refuses
      );
      final result = await job.result.timeout(const Duration(seconds: 10));
      await scheduler.dispose();

      expect(result.isError, isTrue);
      expect(result.content, contains('max nesting depth'));
    });

    test('cancel mid-workflow cancels the in-flight stage and the workflow',
        () async {
      final gate = Completer<void>(); // never completed by us
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'a',
          name: 'a',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://a.test',
          builder: (c) => HoldProvider(
            gate: gate.future,
            releaseEvents: const [
              TextDelta('released'),
              MessageComplete(
                content: [TextBlock('released')],
                stopReason: 'end_turn',
              ),
            ],
          ),
          models: const {
            'a-model': ModelInfo(
                id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final implementer =
          AgentRole(name: 'implementer', description: 'd', modelTier: 'a');
      final tester =
          AgentRole(name: 'tester', description: 'd', modelTier: 'a');
      final qa = Workflow(
        name: 'qa',
        description: 'workflow',
        stages: [
          WorkflowStage(target: implementer, task: 'Implement.'),
          WorkflowStage(target: tester, task: 'Test.'),
        ],
      );
      final cancelPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [implementer, tester],
        workflows: [qa],
      );
      final scheduler = testScheduler(
        r,
        pipeline: cancelPipeline,
        modelTiers: defaultTestTiersExtended,
      );

      final job = scheduler.spawn(
        target: qa,
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await job.cancel();
      final result = await job.result.timeout(const Duration(seconds: 5));
      await scheduler.dispose();

      expect(job.status, SubAgentJobStatus.cancelled);
      expect(result.isError, isTrue);
    });

    test(
        'no deadlock: many concurrent workflows complete under a tight '
        'maxConcurrent (workflows hold no slot)', () async {
      final gate = Completer<void>();
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'a',
          name: 'a',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://a.test',
          builder: (c) => HoldProvider(
            gate: gate.future,
            releaseEvents: const [
              TextDelta('released'),
              MessageComplete(
                content: [TextBlock('released')],
                stopReason: 'end_turn',
              ),
            ],
          ),
          models: const {
            'a-model': ModelInfo(
                id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final s1 = AgentRole(name: 's1', description: 'd', modelTier: 'a');
      final s2 = AgentRole(name: 's2', description: 'd', modelTier: 'a');
      final p = Workflow(
        name: 'p',
        description: 'two-stage',
        stages: [
          WorkflowStage(target: s1, task: 'first'),
          WorkflowStage(target: s2, task: 'second'),
        ],
      );
      final noDeadlockPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [s1, s2],
        workflows: [p],
      );
      final scheduler = testScheduler(
        r,
        pipeline: noDeadlockPipeline,
        maxConcurrent: 2,
        modelTiers: defaultTestTiersExtended,
      );

      // 3 workflows, each 2 sequential stages, under maxConcurrent 2. With the
      // deadlock fix (workflows don't hold a slot) every stage eventually
      // gets a slot; without it, the workflows would hold both slots and
      // block forever on their first stage → timeout.
      final jobs = [
        for (var i = 0; i < 3; i++)
          scheduler.spawn(
            target: p,
            task: 'job $i',
            parentReference: 'a/a-model',
            parentPolicy: PermissionPolicy(),
            originConversationId: 'c1',
          ),
      ];
      gate.complete();
      final results = await Future.wait(
          jobs.map((j) => j.result.timeout(const Duration(seconds: 10))));
      await scheduler.dispose();

      expect(results.every((r) => !r.isError), isTrue);
      expect(jobs.every((j) => j.status == SubAgentJobStatus.done), isTrue);
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  group('workflow DAG', () {
    test('fan-out branches run, then an aggregator sees all their outputs',
        () async {
      final aggSeen = <String>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'a',
          name: 'a',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://a.test',
          builder: (c) => FakeProvider([answerEvents('A-out')], model: c.model),
          models: const {
            'a-model': ModelInfo(
                id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ))
        ..register(ProviderDescriptor(
          id: 'b',
          name: 'b',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://b.test',
          builder: (c) => FakeProvider([answerEvents('B-out')], model: c.model),
          models: const {
            'b-model': ModelInfo(
                id: 'b-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ))
        ..register(ProviderDescriptor(
          id: 'c',
          name: 'c',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://c.test',
          builder: (c) => _RecordingProvider(const ['aggregated'], aggSeen),
          models: const {
            'c-model': ModelInfo(
                id: 'c-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final branchA =
          AgentRole(name: 'branchA', description: 'd', modelTier: 'a');
      final branchB =
          AgentRole(name: 'branchB', description: 'd', modelTier: 'b');
      final aggregator =
          AgentRole(name: 'aggregator', description: 'd', modelTier: 'c');
      final fan = Workflow(
        name: 'fan',
        description: 'fan-out + aggregate',
        stages: [
          WorkflowStage(
              id: 'a', target: branchA, task: 'do A', dependsOn: const []),
          WorkflowStage(
              id: 'b', target: branchB, task: 'do B', dependsOn: const []),
          WorkflowStage(
              id: 'agg',
              target: aggregator,
              task: 'aggregate',
              dependsOn: const ['a', 'b']),
        ],
      );
      final dagPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [branchA, branchB, aggregator],
        workflows: [fan],
      );
      final scheduler = testScheduler(
        r,
        pipeline: dagPipeline,
        modelTiers: defaultTestTiersExtended,
      );

      final job = scheduler.spawn(
        target: fan,
        task: 'THE REQUEST',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      final result = await job.result.timeout(const Duration(seconds: 10));
      await scheduler.dispose();

      expect(result.isError, isFalse);
      expect(result.content, 'aggregated'); // last stage's output
      // The aggregator saw BOTH branches' outputs (deps satisfied before it ran).
      expect(aggSeen, isNotEmpty);
      expect(aggSeen.last, contains('A-out'));
      expect(aggSeen.last, contains('B-out'));
    });

    test('a dependsOn ref to an unknown stage errors', () async {
      final a = AgentRole(name: 'a', description: 'd', modelTier: 'a');
      final w = Workflow(
        name: 'w',
        description: 'bad ref',
        stages: [
          WorkflowStage(target: a, task: 'go', dependsOn: const ['ghost']),
        ],
      );
      final badRefPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [a],
        workflows: [w],
      );
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('x')}),
        pipeline: badRefPipeline,
        modelTiers: defaultTestTiersExtended,
      );
      final job = scheduler.spawn(
        target: w,
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      final result = await job.result.timeout(const Duration(seconds: 10));
      await scheduler.dispose();
      expect(result.isError, isTrue);
      expect(result.content, contains('depends on unknown stage "ghost"'));
    });

    test('a dependency cycle errors', () async {
      final leaf = AgentRole(name: 'leaf', description: 'd', modelTier: 'a');
      final w = Workflow(
        name: 'w',
        description: 'cycle',
        stages: [
          WorkflowStage(
              id: 'a', target: leaf, task: 'go', dependsOn: const ['b']),
          WorkflowStage(
              id: 'b', target: leaf, task: 'go', dependsOn: const ['a']),
        ],
      );
      final cyclePipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [leaf],
        workflows: [w],
      );
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('x')}),
        pipeline: cyclePipeline,
        modelTiers: defaultTestTiersExtended,
      );
      final job = scheduler.spawn(
        target: w,
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      final result = await job.result.timeout(const Duration(seconds: 10));
      await scheduler.dispose();
      expect(result.isError, isTrue);
      expect(result.content, contains('cycle'));
    });

    test('a haltOnFail error in a fan-out aborts the workflow', () async {
      // 'bad' targets an unregistered provider → build fails; haltOnFail aborts
      // before the aggregator runs.
      final good = AgentRole(name: 'good', description: 'd', modelTier: 'a');
      final ugly = AgentRole(name: 'ugly', description: 'd', modelTier: 'x');
      final w = Workflow(
        name: 'w',
        description: 'halt',
        stages: [
          WorkflowStage(
              id: 'ok', target: good, task: 'go', dependsOn: const []),
          WorkflowStage(
              id: 'bad',
              target: ugly,
              task: 'go',
              dependsOn: const [],
              haltOnFail: true),
          WorkflowStage(
              id: 'agg',
              target: good,
              task: 'agg',
              dependsOn: const ['ok', 'bad']),
        ],
      );
      final haltFanPipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [good, ugly],
        workflows: [w],
      );
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('ok-out')}),
        pipeline: haltFanPipeline,
        modelTiers: defaultTestTiersExtended,
      );
      final job = scheduler.spawn(
        target: w,
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      final result = await job.result.timeout(const Duration(seconds: 10));
      await scheduler.dispose();
      expect(result.isError, isTrue);
      expect(result.content, contains('failed to build provider'));
    });
  });

  group('background-tool primitives', () {
    test('jobById finds a job and scopes by conversation', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('x')}),
        pipeline: pipeline,
        modelTiers: defaultTestTiersExtended,
      );
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
        task: 'x',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv-a',
      );

      expect(scheduler.jobById(job.id), same(job));
      expect(scheduler.jobById(job.id, conversation: 'conv-a'), same(job));
      // A different conversation can't see this conversation's job.
      expect(scheduler.jobById(job.id, conversation: 'conv-b'), isNull);
      expect(scheduler.jobById('nope'), isNull);
      await scheduler.dispose();
    });

    test('resolvedResult is populated for done, errored, and cancelled jobs',
        () async {
      // done
      final sDone = testScheduler(
        scriptedRegistry({'a': answerEvents('ok')}),
        pipeline: pipeline,
        modelTiers: defaultTestTiersExtended,
      );
      final jDone = sDone.spawn(
        target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
        task: 'x',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      await jDone.result;
      expect(jDone.resolvedResult, isNotNull);
      expect(jDone.resolvedResult!.isError, isFalse);
      expect(jDone.resolvedResult!.content, 'ok');
      await sDone.dispose();

      // errored: unregistered provider reference → build fails.
      final sErr = testScheduler(
        scriptedRegistry({'a': answerEvents('x')}),
        pipeline: pipeline,
        modelTiers: defaultTestTiersExtended,
      );
      final jErr = sErr.spawn(
        target: const AgentRole(name: 'a', description: 'a', modelTier: 'x'),
        task: 'x',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      await jErr.result;
      expect(jErr.status, SubAgentJobStatus.errored);
      expect(jErr.resolvedResult, isNotNull);
      expect(jErr.resolvedResult!.isError, isTrue);
      await sErr.dispose();

      // cancelled
      final gate = Completer<void>(); // never completed
      final sCan = testScheduler(
        ProviderRegistry(env: {'TEST_KEY': 'k'})
          ..register(ProviderDescriptor(
            id: 'a',
            name: 'a',
            authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
            defaultBaseUrl: 'https://a.test',
            builder: (c) => HoldProvider(
              gate: gate.future,
              releaseEvents: const [
                TextDelta('released'),
                MessageComplete(
                  content: [TextBlock('released')],
                  stopReason: 'end_turn',
                ),
              ],
            ),
            models: const {
              'a-model': ModelInfo(
                  id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
            },
          )),
        pipeline: pipeline,
        modelTiers: defaultTestTiersExtended,
      );
      final jCan = sCan.spawn(
        target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
        task: 'hold',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      await Future<void>.delayed(Duration.zero);
      await jCan.cancel();
      await jCan.result.timeout(const Duration(seconds: 5));
      expect(jCan.status, SubAgentJobStatus.cancelled);
      expect(jCan.resolvedResult, isNotNull);
      expect(jCan.resolvedResult!.isError, isTrue);
      await sCan.dispose();
    });

    test('seedHistory reseeds a leaf: the prior turn is visible to the agent',
        () async {
      final captured = <List<Message>>[];
      final scheduler = testScheduler(
        ProviderRegistry(env: {'TEST_KEY': 'k'})
          ..register(ProviderDescriptor(
            id: 'a',
            name: 'a',
            authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
            defaultBaseUrl: 'https://a.test',
            builder: (c) => CaptureProvider(captured, const ['final']),
            models: const {
              'a-model': ModelInfo(
                  id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
            },
          )),
        pipeline: pipeline,
        modelTiers: defaultTestTiersExtended,
      );

      // A prior conversation: one user turn + one assistant turn.
      final seed = <Message>[
        Message(role: Role.user, content: const [TextBlock('first request')]),
        Message(
            role: Role.assistant, content: const [TextBlock('first answer')]),
      ];
      final job = scheduler.spawn(
        target: const AgentRole(name: 'a', description: 'a', modelTier: 'a'),
        task: 'follow up',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
        seedHistory: seed,
      );
      final result = await job.result.timeout(const Duration(seconds: 5));
      await scheduler.dispose();

      expect(result.content, 'final');
      // The provider saw the seeded prior turn AND the new follow-up: the seed
      // history flowed through to the agent.
      final wire = captured.expand((m) => m).toList();
      expect(
          wire.any((m) => m.content
              .whereType<TextBlock>()
              .any((b) => b.text == 'first request')),
          isTrue);
      expect(
          wire.any((m) => m.content
              .whereType<TextBlock>()
              .any((b) => b.text == 'follow up')),
          isTrue);
      // The grown history is retained on the job for a further continue, and
      // includes the seed exchange, the follow-up, and the new answer.
      expect(job.history, isNotNull);
      final histText = job.history!
          .expand((m) => m.content)
          .whereType<TextBlock>()
          .map((b) => b.text)
          .toSet();
      expect(histText,
          containsAll(['first request', 'first answer', 'follow up', 'final']));
    });

    test('safe-mode strips write/edit/bash from a role\'s registry and policy',
        () async {
      // The role declares read/write/edit/bash (exactly like implementer), but
      // the scheduler is built with safeMode: true. Those three must be gone
      // from both the registry and the derived policy — so a bash request is
      // denied (ask → auto-deny) before any toolStart, exactly as if the role
      // had never declared it. Proves the registry tracks the filtered set.
      final bashThenDone = <List<StreamEvent>>[
        [
          const ToolCallStart(id: 'c1', name: 'bash'),
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'ls'})
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('done'),
          MessageComplete(content: [TextBlock('done')], stopReason: 'end_turn'),
        ],
      ];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'a',
          name: 'a',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://a.test',
          builder: (c) => FakeProvider(bashThenDone, model: c.model),
          models: const {
            'a-model': ModelInfo(
                id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final scheduler = testScheduler(
        r,
        pipeline: pipeline,
        safeMode: true,
      );

      final seen = <AgentEvent>[];
      final sub = scheduler.events.listen(seen.add);

      // modelTier inherits the parent (a); declares write/edit/bash + read.
      final job = scheduler.spawn(
        target: AgentRole(
          name: 'a',
          description: 'a',
          tools: {
            FakeTool.noOp('read'),
            FakeTool.noOp('write'),
            FakeTool.noOp('edit'),
            FakeTool.noOp('bash'),
          },
        ),
        task: 'run ls',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'safe1',
      );
      final result = await job.result;
      await Future<void>.delayed(Duration.zero);
      sub.cancel();

      expect(result.content, 'done');
      // No bash tool *start* reached the bus — it was stripped, so the derived
      // policy denied it before any start.
      final bashStarts = seen.whereType<JobAgentEvent>().where((e) {
        final inner = e.event;
        return inner is ToolAgentEvent &&
            inner.event is ToolStartEvent &&
            (inner.event as ToolStartEvent).toolName == 'bash';
      });
      expect(bashStarts, isEmpty);
      await scheduler.dispose();
    });

    test('a workflow job retains no conversation history', () async {
      final s1 = AgentRole(name: 's1', description: 'd', modelTier: 'a');
      final qa = Workflow(
        name: 'qa',
        description: 'one-stage',
        stages: [WorkflowStage(target: s1, task: 'go')],
      );
      final compositePipeline = AgentPipeline(
        mainRole: const AgentRole(name: 'main', description: 'main'),
        roles: [s1],
        workflows: [qa],
      );
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('out')}),
        pipeline: compositePipeline,
        modelTiers: defaultTestTiersExtended,
      );
      final job = scheduler.spawn(
        target: qa,
        task: 'do it',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
      );
      await job.result.timeout(const Duration(seconds: 5));
      // Workflows orchestrate only — no single conversation to continue.
      expect(job.history, isNull);
      await scheduler.dispose();
    });
  });

  group('runStandalone (attractor seam)', () {
    test('runs a node agent from its system prompt and returns the answer', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('hello from the node')}),
        pipeline: pipeline,
      );
      final sink = FakeAgentSink();
      final result = await scheduler.runStandalone(
        systemPrompt: 'You are a coding agent.',
        task: 'do the thing',
        parentReference: 'a/a-model',
        sink: sink,
      );
      expect(result.isError, isFalse);
      expect(result.text, 'hello from the node');
      // The streamed text reached the sink (the host would render it).
      expect(sink.texts.join(), contains('hello from the node'));
      await scheduler.dispose();
    });

    test('inherits the conversation model when no modelReference is set', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('from-a')}),
        pipeline: pipeline,
      );
      final result = await scheduler.runStandalone(
        systemPrompt: 'id',
        task: 'go',
        parentReference: 'a/a-model',
        sink: FakeAgentSink(),
      );
      // 'a' answers — the node inherited the parent (conversation) model.
      expect(result.text, 'from-a');
      await scheduler.dispose();
    });

    test('a node modelReference overrides the inherited model', () async {
      final scheduler = testScheduler(
        scriptedRegistry(
            {'a': answerEvents('from-a'), 'b': answerEvents('from-b')}),
        pipeline: pipeline,
      );
      final result = await scheduler.runStandalone(
        systemPrompt: 'id',
        task: 'go',
        parentReference: 'a/a-model',
        modelReference: 'b/b-model',
        sink: FakeAgentSink(),
      );
      // 'b' answers, not 'a' — the node's llm_model/llm_provider won.
      expect(result.text, 'from-b');
      await scheduler.dispose();
    });

    test('surfaces a provider-build failure as an error result', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('ok')}),
        pipeline: pipeline,
      );
      final result = await scheduler.runStandalone(
        systemPrompt: 'id',
        task: 'go',
        modelReference: 'ghost/ghost', // no 'ghost' provider registered
        sink: FakeAgentSink(),
      );
      expect(result.isError, isTrue);
      expect(result.text, contains('failed to build provider'));
      await scheduler.dispose();
    });
  });
}
