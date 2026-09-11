import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';

/// A minimal tool whose execute() records the input it was given, so a driver
/// end-to-end run can prove the ToolExecutor chain (and the auto-deny asker)
/// actually ran.
class _EchoTool extends Tool {
  final List<Map<String, dynamic>> seen;
  _EchoTool(this.seen);

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'echo',
        description: 'echoes its input',
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
        },
      );

  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {Future<void>? cancelSignal, ToolOutputCallback? onOutput}) async {
    seen.add(input);
    return ToolResult('echo:${input['text'] ?? ''}');
  }
}

/// A scripted driver: every member is recorded, `run` replays [resultText] by
/// appending one assistant message to the history. Lets a test prove the
/// coordinator invoked the REPLACEMENT, not the default agent build.
class _ScriptedDriver implements AgentDriver {
  final String resultText;
  int runCount = 0;
  List<Message>? lastHistory;
  String? lastUserInput;
  Future<void>? lastCancelSignal;

  _ScriptedDriver(this.resultText);

  @override
  Agent get agent => throw UnimplementedError(
      'the scripted driver drives no concrete agent');

  @override
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
  }) async {
    runCount++;
    lastHistory = history;
    lastUserInput = userInput;
    lastCancelSignal = cancelSignal;
    history.add(Message(
      role: Role.assistant,
      content: [TextBlock(resultText)],
    ));
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
  LlmProvider get provider => throw UnimplementedError();

  @override
  set provider(LlmProvider value) {}

  @override
  Future<bool> compact(List<Message> history,
          {int preserveRecent = 0,
          int preserveRecentMessages = 0,
          Future<void>? cancelSignal}) async =>
      false;
}

/// A factory that hands back [driver] and counts creations — the "real Agent
/// was never built" probe: if the coordinator had built an Agent through the
/// default path it would have needed a provider resolution and a real build,
/// and the run would have gone to that agent instead of recording here.
class _StubFactory implements AgentDriverFactory {
  final AgentDriver driver;
  int creations = 0;
  _StubFactory(this.driver);

  @override
  AgentDriver create(AgentDriverRequest request) {
    creations++;
    return driver;
  }
}

void main() {
  group('AgentDriverAdapter', () {
    test('delegates run to the wrapped agent (turn lands in history + sink)',
        () async {
      final provider = FakeProvider([
        [
          const TextDelta('hello '),
          const MessageComplete(
              content: [TextBlock('hello world')], stopReason: 'end_turn'),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        maxSteps: 4,
        system: 'adapter-system',
      );
      final driver = AgentDriverAdapter(agent);

      final history = <Message>[];
      await driver.run(history: history, userInput: 'hi');

      expect(history, hasLength(2));
      expect(history.last.role, Role.assistant);
      expect((history.last.content.single as TextBlock).text, 'hello world');
      // The streaming delta reached the sink as it was produced.
      expect(sink.texts.join(), contains('hello'));
      expect(provider.calls, hasLength(1));
      expect(provider.calls.single.system, 'adapter-system');
    });

    test('delegates abortedReason/abortedKind, system, tools', () async {
      // maxSteps: 1 + a provider that always demands a tool call → the agent
      // stops with 'max steps reached' / AbortedKind.steps, which the adapter
      // must surface verbatim.
      final provider = FakeProvider([
        [
          MessageComplete(
              content: const [
                ToolUseBlock(id: 'u1', name: 'echo', input: {'text': 'x'})
              ],
              stopReason: 'tool_use'),
        ],
      ]);
      final toolCalls = <Map<String, dynamic>>[];
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([_EchoTool(toolCalls)]),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(
            defaults: const {'echo': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.denyOnce,
        maxSteps: 1,
        system: 'sys-1',
      );
      final driver = AgentDriverAdapter(agent);

      expect(driver.system, 'sys-1');
      expect(driver.tools['echo'], isNotNull);
      expect(driver.abortedReason, isNull,
          reason: 'fresh agent has not aborted yet');
      expect(driver.abortedKind, AbortedKind.none);

      final history = <Message>[];
      await driver.run(history: history, userInput: 'go');

      expect(driver.abortedReason, 'max steps reached');
      expect(driver.abortedKind, AbortedKind.steps);
      expect(toolCalls, hasLength(1), reason: 'the one allowed step ran the tool');
    });

    test('delegates compact to the wrapped agent', () async {
      final provider = FakeProvider([
        answerEvents('long answer one'),
        answerEvents('long answer two'),
        [
          const TextDelta('summary of the earlier turns'),
          const MessageComplete(
              content: [TextBlock('summary of the earlier turns')],
              stopReason: 'end_turn'),
        ],
      ]);
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        maxSteps: 4,
        system: 'sys',
      );
      final driver = AgentDriverAdapter(agent);

      final history = <Message>[];
      await driver.run(history: history, userInput: 'q1');
      await driver.run(history: history, userInput: 'q2');
      final before = history.length;

      final compacted = await driver.compact(history);

      expect(compacted, isTrue);
      expect(history.length, lessThan(before));
      // user+assistant summary exchange replaces the older turns.
      expect(history.length, 2);
      expect(
        history.map((m) => m.role),
        [Role.user, Role.assistant],
      );
      expect(provider.calls, hasLength(3));
    });

    test('provider get/set pass through to the wrapped agent', () async {
      final first = FakeProvider([answerEvents('a')]);
      final agent = Agent(
        provider: first,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        maxSteps: 4,
        system: 'sys',
      );
      final driver = AgentDriverAdapter(agent);

      expect(driver.provider, same(first));

      final second = FakeProvider([answerEvents('b')]);
      driver.provider = second;
      expect(agent.provider, same(second),
          reason: 'the setter must land on the wrapped agent');

      // And the swap takes effect on the next run: the new provider is called.
      final history = <Message>[];
      await driver.run(history: history, userInput: 'hi');
      expect(second.calls, hasLength(1));
      expect(first.calls, isEmpty);
    });
  });

  group('DefaultAgentDriverFactory', () {
    test('builds a driver whose run works end to end (one turn, one tool call)',
        () async {
      final provider = FakeProvider([
        [
          MessageComplete(
              content: const [
                ToolUseBlock(id: 'u1', name: 'echo', input: {'text': 'ping'})
              ],
              stopReason: 'tool_use'),
        ],
        [
          const TextDelta('the tool said '),
          const MessageComplete(
              content: [TextBlock('the tool said echo:ping')],
              stopReason: 'end_turn'),
        ],
      ]);
      final toolCalls = <Map<String, dynamic>>[];
      final sink = FakeAgentSink();
      final driver = const DefaultAgentDriverFactory().create(AgentDriverRequest(
        provider: provider,
        tools: ToolRegistry([_EchoTool(toolCalls)]),
        sink: sink,
        policy: PermissionPolicy(
            defaults: const {'echo': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.denyOnce,
        maxSteps: 4,
        budget: null,
        pauseGate: null,
        system: 'factory-system',
      ));

      expect(driver, isA<AgentDriverAdapter>());
      expect(driver.system, 'factory-system');

      final history = <Message>[];
      await driver.run(history: history, userInput: 'use the tool');

      // The tool ran through the inherited ToolExecutor and its result fed the
      // second provider call, whose answer closed the turn.
      expect(toolCalls, hasLength(1));
      expect(provider.calls, hasLength(2));
      expect(history, hasLength(4));
      // The tool result went back to the provider (the sink shows streamed
      // deltas only — the completion's text is not re-emitted).
      final secondCallTools = provider.calls[1].tools;
      expect(secondCallTools, isNotEmpty);
      expect(driver.abortedReason, isNull,
          reason: 'a clean end_turn leaves no abort reason');
      expect(driver.abortedKind, AbortedKind.none);
      expect(
        history.map((m) => m.role),
        [Role.user, Role.assistant, Role.user, Role.assistant],
      );
    });
  });

  group('driver replacement via SubAgentScheduler', () {
    test('a scripted driver factory serves the delegation; no Agent is built',
        () async {
      final scripted = _ScriptedDriver('scripted-driver-answer');
      final factory = _StubFactory(scripted);
      // The registry is present (the scheduler resolves the model reference
      // against it) but its provider must never be built or driven.
      final registry = scriptedRegistry({'a': answerEvents('from-real-agent')});
      final scheduler = testScheduler(registry, pipeline: defaultTestPipeline)
        ..driverFactory = factory;

      final job = scheduler.spawn(
        task: 'do the thing',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'P',
        parentReference: 'a/a-model',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'conv1',
      );
      final result = await job.result;
      await scheduler.dispose();

      // The replacement was created once and IT ran — with the scheduler's
      // task and cancel signal, not the default agent loop.
      expect(factory.creations, 1);
      expect(scripted.runCount, 1);
      expect(scripted.lastUserInput, 'do the thing');
      expect(scripted.lastCancelSignal, isNotNull);

      // The scheduler extracted ITS result text.
      expect(result.isError, isFalse);
      expect(result.content, 'scripted-driver-answer');

      // The real provider (and thus the real Agent loop) was never driven.
      expect(scripted.lastHistory, isNotNull);
      expect(
        scripted.lastHistory!.where((m) =>
            m.role == Role.assistant &&
            m.content.any((b) => b is TextBlock && b.text == 'from-real-agent')),
        isEmpty,
      );
    });
  });
}
