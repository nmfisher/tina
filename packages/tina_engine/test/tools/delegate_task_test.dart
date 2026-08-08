import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_provider.dart';

/// A provider that records the `system` prompt it receives each turn, so we can
/// assert a delegated sub-agent inherits its parent's system prompt.
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

void main() {
  // The new delegate model (no catalog): a delegation carries a `task` plus an
  // optional tool profile and optional llm_model/llm_provider. The sub-agent
  // inherits the parent agent's system prompt and runs the task.
  final pipeline = defaultTestPipeline;

  SubAgentScheduler sched(ProviderRegistry r) => testScheduler(r, pipeline: pipeline);

  AgentToolContext ctx(SubAgentScheduler scheduler,
          {String parentSystemPrompt = 'PARENT-IDENTITY'}) =>
      testContext(scheduler,
          pipeline: pipeline, parentSystemPrompt: parentSystemPrompt);

  group('schema', () {
    test('name is "delegate"; no agent enum; task is required', () {
      final tool =
          DelegateTool(ctx(sched(scriptedRegistry({'a': answerEvents('x')}))));
      expect(tool.schema.name, 'delegate');
      final props = tool.schema.inputSchema['properties'] as Map;
      final delegations = (props['delegations'] as Map)['items'] as Map;
      final itemProps = delegations['properties'] as Map;
      // No more catalog `agent` enum.
      expect(itemProps.containsKey('agent'), isFalse);
      expect(itemProps.containsKey('task'), isTrue);
      // Tool profile + per-delegation model are selectable.
      expect((itemProps['tools'] as Map)['enum'],
          containsAll(['read-only', 'full']));
      expect(itemProps.containsKey('llm_model'), isTrue);
      expect(itemProps.containsKey('llm_provider'), isTrue);
      // task is the only required field per delegation.
      expect(delegations['required'], ['task']);
    });
  });

  group('identity', () {
    test('a delegated sub-agent inherits the parent system prompt', () async {
      final seen = <String>[];
      final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
        ..register(ProviderDescriptor(
          id: 'a',
          name: 'a',
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://a.test',
          builder: (_) =>
              _SystemCapturingProvider(seen, answerEvents('done')),
          models: const {
            'a-model':
                ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
          },
        ));
      final scheduler = sched(r);
      final tool = DelegateTool(ctx(scheduler, parentSystemPrompt: 'PARENT-ID'));

      final res = await tool.execute({
        'delegations': [
          {'task': 'summarize the auth module'},
        ],
      });

      expect(res.isError, isFalse);
      // The sub-agent ran under the parent's identity, not a catalog role.
      expect(seen.any((s) => s.contains('PARENT-ID')), isTrue);
      await scheduler.dispose();
    });
  });

  group('tool profiles', () {
    test('default (read-only): the sub-agent is denied bash', () async {
      // First call asks for bash (denied — read-only has no bash); second answers.
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
      final scheduler = sched(r);
      final tool = DelegateTool(ctx(scheduler));

      final seen = <AgentEvent>[];
      final sub = scheduler.events.listen(seen.add);

      final res = await tool.execute({
        'delegations': [
          {'task': 'run ls'}, // no `tools` → read-only default
        ],
      });
      await Future<void>.delayed(Duration.zero);
      sub.cancel();

      expect(res.content, contains('done'));
      // No bash tool *start* reached the bus — read-only denied it.
      final bashStarts = seen.whereType<JobAgentEvent>().where((e) {
        final inner = e.event;
        return inner is ToolAgentEvent &&
            inner.event is ToolStartEvent &&
            (inner.event as ToolStartEvent).toolName == 'bash';
      });
      expect(bashStarts, isEmpty);
      await scheduler.dispose();
    });

    test('tools=full: the sub-agent may run bash', () async {
      final bashThenDone = <List<StreamEvent>>[
        [
          const ToolCallStart(id: 'c1', name: 'bash'),
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'echo hi'})
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
      final scheduler = sched(r);
      final tool = DelegateTool(ctx(scheduler));

      final seen = <AgentEvent>[];
      final sub = scheduler.events.listen(seen.add);

      final res = await tool.execute({
        'delegations': [
          {'task': 'run echo', 'tools': 'full'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      sub.cancel();

      expect(res.content, contains('done'));
      // A bash tool *start* reached the bus — full profile allowed it.
      final bashStarts = seen.whereType<JobAgentEvent>().where((e) {
        final inner = e.event;
        return inner is ToolAgentEvent &&
            inner.event is ToolStartEvent &&
            (inner.event as ToolStartEvent).toolName == 'bash';
      });
      expect(bashStarts, isNotEmpty);
      await scheduler.dispose();
    });
  });

  group('model override', () {
    test('llm_provider/llm_model override the inherited model', () async {
      final scheduler = sched(scriptedRegistry(
          {'a': answerEvents('from-a'), 'b': answerEvents('from-b')}));
      final tool = DelegateTool(ctx(scheduler));

      final res = await tool.execute({
        'delegations': [
          {'task': 'go', 'llm_provider': 'b', 'llm_model': 'b-model'},
        ],
      });

      // Parent is a/a-model; the delegation pinned b/b-model → from-b.
      expect(res.content, contains('from-b'));
      await scheduler.dispose();
    });

    test('omitting the override inherits the conversation model', () async {
      final scheduler = sched(scriptedRegistry({'a': answerEvents('from-a')}));
      final tool = DelegateTool(ctx(scheduler));

      final res = await tool.execute({
        'delegations': [
          {'task': 'go'},
        ],
      });

      expect(res.content, contains('from-a'));
      await scheduler.dispose();
    });
  });

  group('fan-out + merge', () {
    test('awaits all sub-agents and merges their answers', () async {
      final scheduler = sched(scriptedRegistry(
          {'a': answerEvents('from-a'), 'b': answerEvents('from-b')}));
      final tool = DelegateTool(ctx(scheduler));

      final res = await tool.execute({
        'delegations': [
          {'task': 't1', 'llm_provider': 'a', 'llm_model': 'a-model'},
          {'task': 't2', 'llm_provider': 'b', 'llm_model': 'b-model'},
        ],
      });

      expect(res.isError, isFalse);
      expect(res.content, contains('from-a'));
      expect(res.content, contains('from-b'));
      await scheduler.dispose();
    });

    test('a delegation without a task is rejected', () async {
      final scheduler = sched(scriptedRegistry({'a': answerEvents('x')}));
      final tool = DelegateTool(ctx(scheduler));

      final res = await tool.execute({
        'delegations': [
          {'task': ''},
        ],
      });
      expect(res.isError, isTrue);
      expect(res.content, contains('task'));
      await scheduler.dispose();
    });
  });

  test('a main-turn cancel propagates to spawned jobs', () async {
    final gate = Completer<void>(); // never completed by us
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => HoldProvider(gate: gate.future),
        models: const {
          'a-model':
              ModelInfo(id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = sched(r);
    final tool = DelegateTool(ctx(scheduler));

    final cancel = Completer<void>();
    final future = tool.execute({
      'delegations': [
        {'task': 'hold'},
      ],
    }, cancelSignal: cancel.future);

    await Future<void>.delayed(Duration.zero); // let the job start
    cancel.complete(); // main-turn ESC

    final res = await future.timeout(const Duration(seconds: 5));
    expect(res.isError, isTrue); // cancelled → error result
    expect(scheduler.jobs.every((j) => j.status == SubAgentJobStatus.cancelled),
        isTrue);
    await scheduler.dispose();
  });
}
