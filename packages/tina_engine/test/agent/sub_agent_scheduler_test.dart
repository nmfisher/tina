import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// A provider that records each turn's user-task text into a shared [sink] and
/// answers [_answers.first]. Built fresh per job by a registry builder that
/// closes over the same [sink]/[_answers], so multi-call assertions share the
/// recorder across calls.
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
      String sessionId, String conversationId, List<Message> messages) async {
    lastReplaced = messages;
  }

  /// The transcript most recently [replace]d, for abort-persistence asserts.
  List<Message>? lastReplaced;
  @override
  Future<List<Message>> loadConversation(
          String sessionId, String conversationId) async =>
      lastReplaced ?? const [];
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
  Future<void> updateSessionUsage(String sessionId, int tokens) async {}
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
  final pipeline = defaultTestPipeline;

  group('model override (modelReference)', () {
    test('a modelReference overrides the inherited model', () async {
      final scheduler = testScheduler(
        scriptedRegistry(
            {'a': answerEvents('from-a'), 'b': answerEvents('from-b')}),
        pipeline: pipeline,
      );
      final job = scheduler.spawn(
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        modelReference: 'b/b-model',
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(result.content, 'from-b');
      await scheduler.dispose();
    });

    test('omitting modelReference inherits the parent reference', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('from-a')}),
        pipeline: pipeline,
      );
      final job = scheduler.spawn(
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
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

  group('identity inheritance', () {
    test('a sub-agent runs under the parent system prompt', () async {
      final seen = <String>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'a',
          name: 'a',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://a.test',
          builder: (_) =>
              _SystemCapturingProvider(seen, answerEvents('ok')),
          models: const {
            'a-model':
                ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final scheduler = testScheduler(r, pipeline: pipeline);

      final withPrompt = scheduler.spawn(
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'CUSTOM-SYS',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      expect((await withPrompt.result).isError, isFalse);
      // The sub-agent ran under the parent's system prompt, verbatim — the
      // scheduler passes it through unchanged (the parent supplies an
      // already-resolved prompt, so there's no re-wrapping here).
      expect(seen.any((s) => s == 'CUSTOM-SYS'), isTrue);
      await scheduler.dispose();
    });
  });

  group('live panelization (panelSink)', () {
    test('a first-class (factory) job becomes a session + wires focus',
        () async {
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
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(capturedAgent, isNotNull, reason: 'factory was invoked');
      expect(wiredFocus, hasLength(1));
      expect(providerAskerCalls, isEmpty);
      wiredFocus.first();
      expect(providerAskerCalls, ['focus']);
      expect(job.panelHost, same(host));
      expect(job.recorder, isNotNull);
      await scheduler.dispose();
    });

    test("an aborted job's transcript records the reason (restore visibility)",
        () async {
      final host = FakeHostInterface();
      final store = _FakeStore();
      final scheduler = testScheduler(
        scriptedRegistry({'a': [const StreamError('no funds')]}),
        pipeline: pipeline,
      );
      scheduler.persistence =
          (job, {required meta, required parentConversationId}) async {
        final conv = await store.createConversationWithMeta('s', meta);
        job.panelSink = FakeAgentSink();
        job.panelHost = host;
        final recorder = SessionRecorder(store, 's', conv, providerId: 'a');
        recorder.attach('s', conv);
        return (conv, recorder);
      };
      final job = scheduler.spawn(
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isTrue);
      // The persisted transcript carries the abort reason as a synthetic
      // assistant message — a restored sub-agent panel shows why it stopped.
      final transcript = store.lastReplaced!;
      expect(
        transcript.last.content
            .whereType<TextBlock>()
            .map((b) => b.text)
            .join(),
        contains('[turn aborted: no funds]'),
      );
      await scheduler.dispose();
    });

    test('a job panelized by persistence streams into its panel sink',
        () async {
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
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(sink, isNotEmpty);
      expect(sink.join(), contains('from-a'));
      await scheduler.dispose();
    });

    test('with no persistence the job streams into the parent chat (fallback)',
        () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('from-a')}),
        pipeline: pipeline,
      );
      final job = scheduler.spawn(
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      expect(result.isError, isFalse);
      expect(result.content, 'from-a');
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
        subAgentBudgetLimit: 100,
      );
      final job = scheduler.spawn(
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
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
      );
      final job = scheduler.spawn(
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
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
        gate.resume(continueDecision: false);
      });
      final scheduler = testScheduler(
        scriptedRegistry({'a': _answerWithUsage('done', 60)}),
        pipeline: pipeline,
        subAgentBudgetLimit: 100,
        pauseGate: gate,
      );
      final job = scheduler.spawn(
        task: 'do it',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
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

  test('a one-step sub-agent returns its final answer', () async {
    final scheduler = testScheduler(
      scriptedRegistry({'a': answerEvents('hello')}),
      pipeline: pipeline,
    );
    final job = scheduler.spawn(
      task: 'do it',
      toolProfile: ToolProfile.readOnly,
      parentSystemPrompt: 'P',
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

  test(
      'a leaf that hits its step ceiling reports a non-finish, not a scavenged '
      'preamble', () async {
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (_) => _LoopingToolProvider(),
        models: const {
          'a-model':
              ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(
      r,
      pipeline: pipeline,
      defaultMaxSteps: 3,
    );
    final job = scheduler.spawn(
      task: 'do it',
      toolProfile: ToolProfile.readOnly,
      parentSystemPrompt: 'P',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'conv1',
    );
    final result = await job.result;
    expect(result.isError, isTrue);
    expect(result.content, contains('did not finish'));
    expect(result.content, isNot(contains('preliminary fragment')));
    expect(job.status, SubAgentJobStatus.errored);
    await scheduler.dispose();
  });

  test('a read-only sub-agent is denied bash (profile gates tools)', () async {
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
          'a-model':
              ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(r, pipeline: pipeline);

    final seen = <AgentEvent>[];
    final sub = scheduler.events.listen(seen.add);

    // read-only has no bash → derived policy denies it (ask → auto-deny) before
    // any toolStart.
    final job = scheduler.spawn(
      task: 'run ls',
      toolProfile: ToolProfile.readOnly,
      parentSystemPrompt: 'P',
      parentReference: 'a/a-model',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'conv1',
    );
    final result = await job.result;
    await Future<void>.delayed(Duration.zero);
    sub.cancel();

    expect(result.content, 'done');
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
          'a-model':
              ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(r, pipeline: pipeline, maxConcurrent: 1);

    SubAgentJob spawn() => scheduler.spawn(
          task: 'hold',
          toolProfile: ToolProfile.readOnly,
          parentSystemPrompt: 'P',
          parentReference: 'a/a-model',
          parentPolicy: PermissionPolicy(),
          originConversationId: 'c1',
        );
    final j1 = spawn();
    final j2 = spawn();

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
    final scheduler = testScheduler(
      scriptedRegistry({'a': answerEvents('from-a')}),
      pipeline: pipeline,
      quota: AgentQuota(maxDepth: 1),
    );
    final job = scheduler.spawn(
      task: 'do it',
      toolProfile: ToolProfile.readOnly,
      parentSystemPrompt: 'P',
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
          'a-model':
              ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final quota = AgentQuota(maxLive: 2);
    final s1 = testScheduler(r, pipeline: pipeline, quota: quota);
    final s2 = testScheduler(r, pipeline: pipeline, quota: quota);

    SubAgentJob spawn(SubAgentScheduler s) => s.spawn(
          task: 'h',
          toolProfile: ToolProfile.readOnly,
          parentSystemPrompt: 'P',
          parentReference: 'a/a-model',
          parentPolicy: PermissionPolicy(),
          originConversationId: 'c1',
        );

    final jobs = [spawn(s1), spawn(s2), spawn(s1)];
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
          'a-model':
              ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(r, pipeline: pipeline);

    final job = scheduler.spawn(
      task: 'hold',
      toolProfile: ToolProfile.readOnly,
      parentSystemPrompt: 'P',
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
          'a-model':
              ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = testScheduler(r, pipeline: pipeline);
    final jobs = [
      for (var i = 0; i < 3; i++)
        scheduler.spawn(
          task: 'hold',
          toolProfile: ToolProfile.readOnly,
          parentSystemPrompt: 'P',
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

  group('background-tool primitives', () {
    test('jobById finds a job and scopes by conversation', () async {
      final scheduler = testScheduler(
        scriptedRegistry({'a': answerEvents('x')}),
        pipeline: pipeline,
      );
      final job = scheduler.spawn(
        task: 'x',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv-a',
      );

      expect(scheduler.jobById(job.id), same(job));
      expect(scheduler.jobById(job.id, conversation: 'conv-a'), same(job));
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
      );
      final jDone = sDone.spawn(
        task: 'x',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
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
      );
      final jErr = sErr.spawn(
        task: 'x',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
        modelReference: 'ghost/ghost',
      );
      await jErr.result;
      expect(jErr.status, SubAgentJobStatus.errored);
      expect(jErr.resolvedResult, isNotNull);
      expect(jErr.resolvedResult!.isError, isTrue);
      await sErr.dispose();

      // cancelled
      final gate = Completer<void>();
      final sCan = testScheduler(
        ProviderRegistry(env: {'TEST_KEY': 'k'})
          ..register(ProviderDescriptor(
            id: 'a',
            name: 'a',
            authSources:
                const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
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
              'a-model':
                  ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
            },
          )),
        pipeline: pipeline,
      );
      final jCan = sCan.spawn(
        task: 'hold',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
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
            authSources:
                const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
            defaultBaseUrl: 'https://a.test',
            builder: (c) => CaptureProvider(captured, const ['final']),
            models: const {
              'a-model':
                  ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
            },
          )),
        pipeline: pipeline,
      );

      final seed = <Message>[
        Message(role: Role.user, content: const [TextBlock('first request')]),
        Message(
            role: Role.assistant, content: const [TextBlock('first answer')]),
      ];
      final job = scheduler.spawn(
        task: 'follow up',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'c1',
        seedHistory: seed,
      );
      final result = await job.result.timeout(const Duration(seconds: 5));
      await scheduler.dispose();

      expect(result.content, 'final');
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
      expect(job.history, isNotNull);
      final histText = job.history!
          .expand((m) => m.content)
          .whereType<TextBlock>()
          .map((b) => b.text)
          .toSet();
      expect(histText,
          containsAll(['first request', 'first answer', 'follow up', 'final']));
    });

    test('safe-mode strips write/edit/bash from a full profile + policy',
        () async {
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
            'a-model':
                ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final scheduler = testScheduler(r, pipeline: pipeline, safeMode: true);

      final seen = <AgentEvent>[];
      final sub = scheduler.events.listen(seen.add);

      // full profile under safe-mode → bash stripped, so the derived policy
      // denies it before any start.
      final job = scheduler.spawn(
        task: 'run ls',
        toolProfile: ToolProfile.full,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'safe1',
      );
      final result = await job.result;
      await Future<void>.delayed(Duration.zero);
      sub.cancel();

      expect(result.content, 'done');
      final bashStarts = seen.whereType<JobAgentEvent>().where((e) {
        final inner = e.event;
        return inner is ToolAgentEvent &&
            inner.event is ToolStartEvent &&
            (inner.event as ToolStartEvent).toolName == 'bash';
      });
      expect(bashStarts, isEmpty);
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
        modelReference: 'ghost/ghost',
        sink: FakeAgentSink(),
      );
      expect(result.isError, isTrue);
      expect(result.text, contains('failed to build provider'));
      await scheduler.dispose();
    });

    test('toolProfile readOnly yields the read-only set and no delegate',
        () async {
      final provider = _RecordingToolsProvider();
      final registry = ProviderRegistry(env: const {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'rec',
          name: 'rec',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://rec.test',
          builder: (_) => provider,
          models: {
            'rec-model': ModelInfo(
                id: 'rec-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final scheduler = SubAgentScheduler(
        registry: registry,
        pipeline: pipeline,
        maxTokens: 8192,
        streamIdleTimeout: const Duration(seconds: 60),
        requestTimeout: const Duration(seconds: 30),
        // Wire nesting so the test proves includeDelegate: false drops it.
        delegateToolBuilder: (ctx) => DelegateTool(ctx),
      );
      final result = await scheduler.runStandalone(
        systemPrompt: 'id',
        task: 'go',
        parentReference: 'rec/rec-model',
        sink: FakeAgentSink(),
        toolProfile: ToolProfile.readOnly,
        includeDelegate: false,
      );
      expect(result.isError, isFalse);
      final names = provider.toolNames.single;
      expect(names, isNot(contains('write')));
      expect(names, isNot(contains('bash')));
      expect(names, containsAll(['read', 'grep', 'glob', 'write_summary']));
      expect(names, isNot(contains('delegate')));
      await scheduler.dispose();
    });

    test('defaults keep the full tool profile plus delegate', () async {
      final provider = _RecordingToolsProvider();
      final registry = ProviderRegistry(env: const {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'rec',
          name: 'rec',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://rec.test',
          builder: (_) => provider,
          models: {
            'rec-model': ModelInfo(
                id: 'rec-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final scheduler = SubAgentScheduler(
        registry: registry,
        pipeline: pipeline,
        maxTokens: 8192,
        streamIdleTimeout: const Duration(seconds: 60),
        requestTimeout: const Duration(seconds: 30),
        delegateToolBuilder: (ctx) => DelegateTool(ctx),
      );
      final result = await scheduler.runStandalone(
        systemPrompt: 'id',
        task: 'go',
        parentReference: 'rec/rec-model',
        sink: FakeAgentSink(),
      );
      expect(result.isError, isFalse);
      final names = provider.toolNames.single;
      expect(names, containsAll(['write', 'bash', 'delegate']));
      await scheduler.dispose();
    });
  });
}

/// A provider that records the tool schemas each turn was given — the only way
/// to observe which tool set `runStandalone` built for an agent.
class _RecordingToolsProvider extends LlmProvider {
  final List<List<String>> toolNames = [];
  _RecordingToolsProvider() : super('rec');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    toolNames.add([for (final t in tools) t.name]);
    yield MessageComplete(
        content: const [TextBlock('done')], stopReason: 'end_turn');
  }
}
