import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

/// A provider that always yields one [StreamError] — the wire shape of a
/// remote failure (API error, rate limit, insufficient funds, a tripped
/// global ceiling).
class _FailingProvider extends LlmProvider {
  final String error;
  _FailingProvider(this.error) : super('fail');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) =>
      Stream.fromIterable([StreamError(error)]);
}

/// Builds an [Agent] wired with fakes. The default asker denies, but tests that
/// need tools to run pass a permissive [policy] (e.g. `bash: allow`) so the
/// asker is never consulted.
Agent _agent({
  required LlmProvider provider,
  required ToolRegistry tools,
  required FakeAgentSink sink,
  PermissionPolicy? policy,
  int maxSteps = 50,
  ToolResultVerifier? resultVerifier,
  HistoryAppendObserver? onHistoryAppend,
  HistoryReplaceObserver? onHistoryReplace,
}) =>
    Agent(
      provider: provider,
      tools: tools,
      sink: sink,
      policy: policy ?? PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      maxSteps: maxSteps,
      system: 'sys',
      resultVerifier: resultVerifier,
      onHistoryAppend: onHistoryAppend,
      onHistoryReplace: onHistoryReplace,
    );

/// A tool that emits incremental output via [onOutput] (like a real BashTool
/// streaming a build log), then completes. Used to exercise the agent's
/// streaming-output wiring.
class _StreamingTool implements Tool {
  @override
  final ToolSchema schema;
  final List<String> chunks;
  _StreamingTool(String name, {required this.chunks})
      : schema = ToolSchema(
          name: name,
          description: 'streaming $name',
          inputSchema: const {'type': 'object', 'properties': {}},
        );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    for (final chunk in chunks) {
      onOutput?.call(chunk);
    }
    return ToolResult('finished');
  }
}

/// A provider whose stream stays open and fires [cancel] once consume has
/// subscribed — modeling ESC arriving mid-stream. The stream never yields a
/// [MessageComplete], so the only way the turn ends is via cancellation.
class _CancelMidStreamProvider extends LlmProvider {
  final Completer<void> cancel;
  _CancelMidStreamProvider(this.cancel) : super('cancellable');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    final controller = StreamController<StreamEvent>(sync: true);
    controller.add(const TextDelta('streaming'));
    // Fire cancel on the next microtask, once consume is parked on
    // `await done.future`.
    scheduleMicrotask(cancel.complete);
    // Intentionally never closed — the cancel tears it down.
    return controller.stream;
  }
}

/// A scripted verifier seam for the #22a tests. The engine typedef is a plain
/// function type (no interface to implement), so the test wraps a lambda in a
/// mutable holder that records each call.
class _VerifierScript {
  final List<String> calls = [];
  String? Function(String toolName, Map<String, dynamic> input) verdict =
      (_, __) => null;

  Future<String?> call(String toolName, Map<String, dynamic> input) async {
    calls.add(toolName);
    return verdict(toolName, input);
  }
}

void main() {
  // The activity lifecycle (tin-y4qn) is Agent.run's own duty: every run
  // path — the session turn loop, runStandalone, the environment ceremony,
  // summaries — inherits it from here, so no caller can forget to raise or
  // clear the busy cue. These pin the contract at the source; the path-level
  // matrix is pinned where each path lives (sub_agent_scheduler_test's
  // delegation + standalone groups, tina's panel_busy_cue_test for the turn
  // loop).
  group('Agent.run activity lifecycle', () {
    Agent hostAgent(LlmProvider provider, FakeHostInterface host) => Agent(
          provider: provider,
          tools: ToolRegistry(const []),
          sink: host,
          policy: PermissionPolicy(),
          asker: (_) async => PermissionResponse.denyOnce,
          system: 'sys',
        );

    test('raises the host signal on entry and clears it on exit', () async {
      final host = FakeHostInterface();
      final agent = hostAgent(
        FakeProvider([
          [
            const TextDelta('ok'),
            const MessageComplete(
              content: [TextBlock('ok')],
              stopReason: 'end_turn',
            ),
          ],
        ]),
        host,
      );
      await agent.run(history: [], userInput: 'hi');
      expect(host.activitySignals, [true, false]);
    });

    test('clears on a failed stream too (every exit path)', () async {
      final host = FakeHostInterface();
      final agent = hostAgent(_FailingProvider('429 Too Many Requests'), host);
      await agent.run(history: [], userInput: 'hi');
      expect(host.activitySignals, [true, false],
          reason: 'a provider error must not leave the busy cue stuck on');
    });

    test('clears on cancellation', () async {
      final host = FakeHostInterface();
      final cancel = Completer<void>();
      final agent = hostAgent(_CancelMidStreamProvider(cancel), host);
      await agent
          .run(history: [], userInput: 'hi', cancelSignal: cancel.future);
      expect(host.activitySignals, [true, false],
          reason: 'a cancelled turn must not leave the busy cue stuck on');
    });

    test('a plain AgentSink (not a host) runs untouched', () async {
      // Telemetry sinks and the headless no-op have no signal to drive; the
      // run must proceed normally through them.
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: FakeProvider([
          [
            const TextDelta('ok'),
            const MessageComplete(
              content: [TextBlock('ok')],
              stopReason: 'end_turn',
            ),
          ],
        ]),
        tools: ToolRegistry(const []),
        sink: sink,
      );
      await agent.run(history: [], userInput: 'hi');
      expect(sink.texts, ['ok']);
    });

    test('an empty completion is retried, not recorded as a clean finish',
        () async {
      // Seen in the wild: an overloaded worker returns 200 with zero content
      // blocks. The turn must NOT end there (a headless run would exit 0
      // having done nothing) and the empty message must not reach history.
      final provider = FakeProvider([
        [
          const MessageComplete(content: [], stopReason: 'end_turn'),
        ],
        [
          const TextDelta('recovered'),
          const MessageComplete(
            content: [TextBlock('recovered')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      expect(agent.abortedReason, isNull);
      expect(sink.texts, ['recovered']);
      expect(
          history.where((m) => m.role == Role.assistant).map((m) => m.content),
          everyElement(isNotEmpty),
          reason: 'the degenerate empty message is never appended');
      expect(sink.notices.map((n) => n.message),
          contains(contains('empty completion')),
          reason: 'the retry is visible, not silent');
    });

    test('two consecutive empty completions abort the run loudly', () async {
      final provider = FakeProvider([
        [
          const MessageComplete(content: [], stopReason: 'end_turn'),
        ],
        [
          const MessageComplete(content: [], stopReason: 'end_turn'),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      expect(agent.abortedReason, 'model returned an empty completion');
      expect(history.where((m) => m.role == Role.assistant), isEmpty);
    });
  });

  group('Agent.run', () {
    test('single turn with no tools emits text and appends to history',
        () async {
      final provider = FakeProvider([
        [
          const TextDelta('hello'),
          const MessageComplete(
            content: [TextBlock('hello')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      expect(sink.texts, ['hello']);
      expect(provider.calls, hasLength(1));
      expect(history, hasLength(2)); // user + assistant
      expect(history[0].role, Role.user);
      expect(history[1].role, Role.assistant);
      expect(history[1].content.single, isA<TextBlock>());
    });

    // tin-p2sq: a model whose tool-call arguments are not valid JSON (the
    // quote-heavy shell one-liner case) must not lose the turn. The agent
    // answers the call with an error result and the model retries — the tool
    // itself never runs with garbage input.
    test('malformed tool arguments become an error result, not a dead turn',
        () async {
      var executed = 0;
      final provider = FakeProvider([
        [
          const MessageComplete(
            content: [
              TextBlock('Counting first.'),
              ToolUseBlock(
                id: 'c1',
                name: 'bash',
                input: {},
                argumentsParseError: 'Unterminated string (at character 349)',
              ),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('recovered'),
          const MessageComplete(
            content: [TextBlock('recovered')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('bash', (_) {
            executed++;
            return ToolResult('ran');
          }),
        ]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'bash': PermissionDecision.allow}),
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'what tests do we have?');

      expect(executed, 0, reason: 'the malformed call must not reach the tool');
      expect(sink.toolStarts, isEmpty);
      // The turn continued: the model saw the error and answered.
      expect(provider.calls, hasLength(2));
      expect(sink.texts, ['recovered']);
      // user → assistant(text+bad tool_use) → user(tool_result error) → text
      expect(history, hasLength(4));
      final result = history[2].content.single as ToolResultBlock;
      expect(result.toolUseId, 'c1');
      expect(result.isError, isTrue);
      expect(result.content, contains('not valid JSON'));
      expect(result.content, contains('Unterminated string'));
      // And the retry really can call the tool: a good call on the next step
      // executes normally.
      expect(agent.abortedKind, AbortedKind.none);
    });

    test('a retried good call after a malformed one executes (tin-p2sq)',
        () async {
      final inputs = <Map<String, dynamic>>[];
      final provider = FakeProvider([
        [
          const MessageComplete(
            content: [
              ToolUseBlock(
                id: 'c1',
                name: 'bash',
                input: {},
                argumentsParseError: 'Unterminated string',
              ),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const MessageComplete(
            content: [
              ToolUseBlock(
                id: 'c2',
                name: 'bash',
                input: {
                  'command': r'echo "done: \"$?\""',
                },
              ),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const MessageComplete(
            content: [TextBlock('all set')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('bash', (input) {
            inputs.add(input);
            return ToolResult('ok');
          }),
        ]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'bash': PermissionDecision.allow}),
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'run it');

      expect(
          inputs,
          [
            {'command': r'echo "done: \"$?\""'},
          ],
          reason:
              'only the well-formed retry reaches the tool, input verbatim');
      expect(sink.toolCompletes.single.isError, isFalse);
      expect(provider.calls, hasLength(3));
    });

    test('tool loop: result is fed back and the model finishes', () async {
      final provider = FakeProvider([
        [
          const ToolCallStart(id: 'c1', name: 'bash'),
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'ls'}),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('done'),
          const MessageComplete(
            content: [TextBlock('done')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry([FakeTool('bash', (_) => ToolResult('file.txt'))]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'bash': PermissionDecision.allow}),
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'run ls');

      expect(sink.toolStarts.single.toolName, 'bash');
      expect(sink.toolCompletes.single.isError, isFalse);
      expect(sink.toolCompletes.single.result, 'file.txt');
      expect(sink.texts, ['done']);
      expect(provider.calls, hasLength(2));
      // user → assistant(tool_use) → user(tool_result) → assistant(text)
      expect(history, hasLength(4));
      expect(history[2].role, Role.user);
      expect(history[2].content.single, isA<ToolResultBlock>());
    });

    test('multiple tool calls in one turn all execute and are fed back',
        () async {
      final inputs = <Map<String, dynamic>>[];
      final provider = FakeProvider([
        [
          const ToolCallStart(id: 'a', name: 'read'),
          const ToolCallStart(id: 'b', name: 'read'),
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'a', name: 'read', input: {'filePath': 'a.txt'}),
              ToolUseBlock(id: 'b', name: 'read', input: {'filePath': 'b.txt'}),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('both done'),
          const MessageComplete(
            content: [TextBlock('both done')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('read', (input) {
            inputs.add(input);
            return ToolResult('content-of-${input['filePath']}');
          }),
        ]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'read': PermissionDecision.allow}),
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'read both');

      expect(sink.toolStarts, hasLength(2));
      expect(
        sink.toolCompletes.map((e) => e.result),
        ['content-of-a.txt', 'content-of-b.txt'],
      );
      expect(inputs.map((m) => m['filePath']), ['a.txt', 'b.txt']);
      // Both results land in the single user(tool_result) message.
      expect(history[2].content.whereType<ToolResultBlock>(), hasLength(2));
      expect(provider.calls, hasLength(2));
    });

    test('unknown tool produces an error result and the loop continues',
        () async {
      final provider = FakeProvider([
        [
          const ToolCallStart(id: 'c1', name: 'nonexistent'),
          const MessageComplete(
            content: [ToolUseBlock(id: 'c1', name: 'nonexistent', input: {})],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('recovered'),
          const MessageComplete(
            content: [TextBlock('recovered')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []), // empty registry → tool not found
        sink: sink,
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'try it');

      expect(sink.toolStarts, isEmpty); // never reached execution
      expect(
          sink.notices.any((n) => n.message.contains('unknown tool')), isTrue);
      expect(sink.texts, ['recovered']); // loop continued to a second call
      expect(provider.calls, hasLength(2));
    });

    test('a thrown tool is routed through toolComplete as an error', () async {
      final provider = FakeProvider([
        [
          const ToolCallStart(id: 'c1', name: 'bash'),
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'x'}),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('recovered'),
          const MessageComplete(
            content: [TextBlock('recovered')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools:
            ToolRegistry([FakeTool('bash', (_) => throw StateError('boom'))]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'bash': PermissionDecision.allow}),
      );

      await agent.run(history: <Message>[], userInput: 'go');

      expect(sink.toolCompletes.single.isError, isTrue);
      expect(sink.toolCompletes.single.result, contains('boom'));
      expect(sink.texts, ['recovered']); // loop continued
    });

    test('hitting the maxSteps ceiling emits a warning notice', () async {
      // Every call asks for a tool, so the loop never exits naturally.
      final loopResponse = [
        const ToolCallStart(id: 'c1', name: 'bash'),
        const MessageComplete(
          content: [
            ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'echo'}),
          ],
          stopReason: 'tool_use',
        ),
      ];
      final provider = FakeProvider(List.filled(10, loopResponse));
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry([FakeTool('bash', (_) => ToolResult('ok'))]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'bash': PermissionDecision.allow}),
        maxSteps: 3,
      );

      await agent.run(history: <Message>[], userInput: 'loop');

      expect(sink.notices.any((n) => n.message.contains('max steps')), isTrue);
      expect(provider.calls, hasLength(3)); // exactly maxSteps provider calls
      expect(agent.abortedReason, 'max steps reached');
    });

    test('abortedReason records provider errors and resets on the next run',
        () async {
      final provider = _FailingProvider('server exploded');
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
      );

      await agent.run(history: <Message>[], userInput: 'go');
      expect(agent.abortedReason, 'server exploded');
      // The abort reason is never appended to history — extraction must not
      // mistake it for a real answer.
      expect(
          sink.notices.any((n) => n.message.contains('error: server exploded')),
          isTrue);

      // The field resets at the top of the next run.
      final okProvider = FakeProvider(
          [answerEvents('hello from the agent')]); // ignores, just runs
      final agent2 = _agent(
        provider: okProvider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
      );
      await agent2.run(history: <Message>[], userInput: 'go');
      expect(agent2.abortedReason, isNull);
    });

    test('cancelSignal during the stream cancels the turn cleanly', () async {
      final cancel = Completer<void>();
      final provider = _CancelMidStreamProvider(cancel);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
      );

      await agent.run(
        history: <Message>[],
        userInput: 'go',
        cancelSignal: cancel.future,
      );

      expect(sink.notices.any((n) => n.message.contains('cancelled')), isTrue);
      expect(sink.toolStarts, isEmpty); // no tool ran
    });

    test('a normal turn completes even with a never-firing cancelSignal',
        () async {
      // Regression: consume used to `await cancelSub` unconditionally, which
      // deadlocked any turn whose cancelSignal never fires. The REPL passes a
      // non-null cancelSignal on every turn (it only completes on ESC), so
      // this path must not hang.
      final provider = FakeProvider([
        [
          const TextDelta('hello'),
          const MessageComplete(
            content: [TextBlock('hello')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
      );
      final neverFires = Completer<void>().future;

      await agent.run(
        history: <Message>[],
        userInput: 'hi',
        cancelSignal: neverFires,
      ).timeout(const Duration(seconds: 3));

      expect(sink.texts, ['hello']);
      expect(provider.calls, hasLength(1));
    });

    test('a tool streaming via onOutput reaches sink.toolOutput', () async {
      final provider = FakeProvider([
        [
          const ToolCallStart(id: 'c1', name: 'bash'),
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'c1', name: 'bash', input: {'command': 'build'}),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('ok'),
          const MessageComplete(
            content: [TextBlock('ok')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry([
          _StreamingTool('bash', chunks: ['compiling...', 'done']),
        ]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'bash': PermissionDecision.allow}),
      );

      await agent.run(history: <Message>[], userInput: 'build');

      expect(sink.toolOutputs.map((e) => e.chunk), ['compiling...', 'done']);
      expect(sink.toolOutputs.every((e) => e.toolName == 'bash'), isTrue);
    });
  });

  group('Agent.run denied tool call', () {
    // A denial is the model's chance to self-correct: the tool_result must
    // name the allowed shapes for that tool (so it can rephrase) and, for
    // bash, the always-allowed native tools, instead of a bare one-liner.
    FakeProvider denyProvider(String tool, Map<String, dynamic> input) =>
        FakeProvider([
          [
            MessageComplete(
                content: [ToolUseBlock(id: 'd1', name: tool, input: input)],
                stopReason: 'tool_use'),
          ],
          answerEvents('ok'),
        ]);

    ToolResultBlock deniedResult(List<Message> history) =>
        history.lastWhere((m) => m.role == Role.user).content.single
            as ToolResultBlock;

    test('denied bash result lists the bash allow patterns in the policy',
        () async {
      final policy = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash',
            pattern: 'dart *',
            decision: PermissionDecision.allow),
        PermissionRule(
            toolName: 'bash',
            pattern: 'cd *',
            decision: PermissionDecision.allow),
        PermissionRule(
            toolName: 'write',
            pattern: '/tmp/*',
            decision: PermissionDecision.allow),
      ]);
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: denyProvider('bash', {'command': 'rm -rf /tmp/x'}),
        tools: ToolRegistry([FakeTool('bash', (_) => ToolResult('ran'))]),
        sink: sink,
        policy: policy,
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'sys',
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'clean up');

      expect(sink.toolStarts, isEmpty,
          reason: 'the denied call must not reach the tool');
      final result = deniedResult(history);
      expect(result.toolUseId, 'd1');
      expect(result.isError, isTrue);
      expect(result.content, contains('Denied by permission policy'));
      expect(result.content, contains('bash:dart *'));
      expect(result.content, contains('bash:cd *'));
      expect(result.content, isNot(contains('write:')),
          reason: 'other tools’ rules must not leak into the hint');
      expect(result.content, contains('Do not retry the same call unchanged'));
    });

    test(
        'denied bash with no bash allow rules says none and names the native '
        'tools', () async {
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: denyProvider('bash', {'command': 'rm -rf /tmp/x'}),
        tools: ToolRegistry([FakeTool('bash', (_) => ToolResult('ran'))]),
        sink: sink,
        policy: PermissionPolicy(), // no rules at all
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'sys',
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'clean up');

      final result = deniedResult(history);
      expect(result.isError, isTrue);
      expect(result.content, contains('Denied by permission policy'));
      expect(result.content, contains('Allowed bash patterns: none'));
      for (final native in ['ls', 'stat', 'glob', 'grep', 'search', 'git']) {
        expect(result.content, contains(native),
            reason: 'bash denies must point at the $native tool');
      }
      expect(result.content, contains('Do not retry the same call unchanged'));
    });

    test('a denied non-bash tool gets the pattern list but no bash pointer',
        () async {
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: denyProvider('write', {'filePath': '/etc/hosts'}),
        tools: ToolRegistry([FakeTool('write', (_) => ToolResult('ok'))]),
        sink: sink,
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'sys',
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'edit it');

      final result = deniedResult(history);
      expect(result.isError, isTrue);
      expect(result.content, contains('Denied by permission policy'));
      expect(result.content, contains('Allowed write patterns: none'));
      expect(result.content, isNot(contains('always-allowed tools')));
      expect(result.content, contains('Do not retry the same call unchanged'));
    });

    test('asker refusal note is appended to the denial result (#27)', () async {
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: denyProvider('write', {'filePath': '/etc/hosts'}),
        tools: ToolRegistry([FakeTool('write', (_) => ToolResult('ok'))]),
        sink: sink,
        policy: PermissionPolicy(),
        asker: (_) async => const PermissionResponse(PermissionDecision.deny,
            note: 'Non-interactive run: permission asks are auto-refused.'),
        system: 'sys',
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'edit it');

      final result = deniedResult(history);
      expect(result.isError, isTrue);
      expect(result.content, contains('Denied by permission policy'));
      expect(result.content,
          contains('Non-interactive run: permission asks are auto-refused.'),
          reason: 'the model-facing note must ride on the tool result');
    });

    test('static rule denial has no note (asker never consulted)', () async {
      final sink = FakeAgentSink();
      // A static deny RULE short-circuits before the asker — its remedy is
      // the allowed-shapes text, so no asker note is expected there.
      final agent = Agent(
        provider: denyProvider('write', {'filePath': '/etc/passwd'}),
        tools: ToolRegistry([FakeTool('write', (_) => ToolResult('ok'))]),
        sink: sink,
        policy: PermissionPolicy(rules: const [
          PermissionRule(
              toolName: 'write',
              pattern: '/etc/*',
              decision: PermissionDecision.deny),
        ]),
        asker: (_) async => const PermissionResponse(PermissionDecision.deny,
            note: 'asker note that must NOT appear'),
        system: 'sys',
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'edit it');

      final result = deniedResult(history);
      expect(result.content, contains('Denied by permission policy'));
      expect(result.content, isNot(contains('asker note')),
          reason: 'a rule deny never went through the asker');
    });

    test(
        'three consecutive denials of one tool attach a stop-calling '
        'notice (#27)', () async {
      // Four scripted denials of the SAME tool: the breaker line appears
      // from the third denial on, and the counter keeps counting.
      final provider = FakeProvider([
        [
          MessageComplete(content: [
            ToolUseBlock(id: 'd1', name: 'bash', input: {'command': 'rm -rf /'})
          ], stopReason: 'tool_use'),
        ],
        [
          MessageComplete(content: [
            ToolUseBlock(
                id: 'd2', name: 'bash', input: {'command': 'rm -rf /*'})
          ], stopReason: 'tool_use'),
        ],
        [
          MessageComplete(content: [
            ToolUseBlock(id: 'd3', name: 'bash', input: {'command': 'rm -rf .'})
          ], stopReason: 'tool_use'),
        ],
        [
          MessageComplete(content: [
            ToolUseBlock(
                id: 'd4', name: 'bash', input: {'command': 'rm -rf ..'})
          ], stopReason: 'tool_use'),
        ],
        answerEvents('ok'),
      ]);
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([FakeTool('bash', (_) => ToolResult('ran'))]),
        sink: sink,
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'sys',
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'clean up');

      final toolResults = history
          .whereType<Message>()
          .where((m) => m.role == Role.user)
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .toList();
      expect(toolResults, hasLength(4));
      // Denials 1 and 2: plain denial, no breaker line yet.
      expect(toolResults[0].content, isNot(contains('consecutive')));
      expect(toolResults[1].content, isNot(contains('consecutive')));
      // Denials 3 and 4: the circuit-breaker notice rides the result.
      expect(toolResults[2].content, contains('3 consecutive bash denials'));
      expect(toolResults[2].content, contains('Stop calling'));
      expect(toolResults[3].content, contains('4 consecutive bash denials'));
      // The trip is also visible on the sink, for operators watching stderr.
      expect(
          sink.notices.any((n) =>
              n.message.contains('consecutive denials this turn') &&
              n.kind == NoticeKind.warning),
          isTrue);
    });

    test('a successful call resets the denial streak (#27)', () async {
      // deny, deny, ALLOW (tool runs), deny: the final denial must be the
      // FIRST of a fresh streak — no breaker line — proving the counter
      // cleared on success.
      final provider = FakeProvider([
        [
          MessageComplete(content: [
            ToolUseBlock(id: 'd1', name: 'bash', input: {'command': 'rm -rf /'})
          ], stopReason: 'tool_use'),
        ],
        [
          MessageComplete(content: [
            ToolUseBlock(
                id: 'd2', name: 'bash', input: {'command': 'rm -rf /*'})
          ], stopReason: 'tool_use'),
        ],
        [
          MessageComplete(content: [
            ToolUseBlock(id: 'ok1', name: 'bash', input: {'command': 'ls -la'})
          ], stopReason: 'tool_use'),
        ],
        [
          MessageComplete(content: [
            ToolUseBlock(id: 'd3', name: 'bash', input: {'command': 'rm -rf .'})
          ], stopReason: 'tool_use'),
        ],
        answerEvents('ok'),
      ]);
      final sink = FakeAgentSink();
      // Static allow for the exact successful command; the rm commands ask
      // (default) and get refused by the asker below.
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([FakeTool('bash', (_) => ToolResult('ran'))]),
        sink: sink,
        policy: PermissionPolicy(rules: const [
          PermissionRule(
              toolName: 'bash',
              pattern: 'ls -la',
              decision: PermissionDecision.allow),
        ]),
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'sys',
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'clean up');

      final toolResults = history
          .whereType<Message>()
          .where((m) => m.role == Role.user)
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .toList();
      expect(toolResults, hasLength(4));
      expect(toolResults[0].content, isNot(contains('consecutive')));
      expect(toolResults[1].content, isNot(contains('consecutive')));
      expect(toolResults[2].isError, isFalse,
          reason: 'the allowed call must have actually run');
      expect(toolResults[3].content, isNot(contains('consecutive')),
          reason: 'the success reset the streak, so this is denial #1 again');
    });
  });

  group('Agent.compact', () {
    test('replaces history with a single summarized exchange', () async {
      final provider = FakeProvider([
        [
          const TextDelta('summary bullets'),
          const MessageComplete(
            content: [TextBlock('summary bullets')],
            stopReason: 'end_turn',
          ),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('old user')]),
        const Message(
            role: Role.assistant, content: [TextBlock('old assistant')]),
      ];

      await agent.compact(history);

      expect(history, hasLength(2));
      expect(history[0].role, Role.user);
      expect(history[1].role, Role.assistant);
      expect(
          sink.texts, ['summary bullets']); // summary streamed through the sink
    });

    test('an empty summary reports failure and leaves history untouched',
        () async {
      // An empty event list: the stream closes with no text → empty summary.
      final provider = FakeProvider([[]]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('q')]),
        const Message(role: Role.assistant, content: [TextBlock('a')]),
      ];

      await agent.compact(history);

      expect(sink.notices.any((n) => n.message.contains('compact failed')),
          isTrue);
      expect(history, hasLength(2));
      expect((history[0].content.single as TextBlock).text, 'q');
      expect((history[1].content.single as TextBlock).text, 'a');
    });

    test('preserveRecent keeps the most recent human turn intact', () async {
      final provider = FakeProvider([
        [
          const TextDelta('summary'),
          const MessageComplete(
              content: [TextBlock('summary')], stopReason: 'end_turn'),
        ],
      ]);
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('old q')]),
        const Message(role: Role.assistant, content: [TextBlock('old a')]),
        const Message(role: Role.user, content: [TextBlock('recent q')]),
        const Message(role: Role.assistant, content: [TextBlock('recent a')]),
      ];

      final compacted = await agent.compact(history, preserveRecent: 1);

      expect(compacted, isTrue);
      // [summary-user, summary-assistant, recent q, recent a]
      expect(history, hasLength(4));
      expect((history[2].content.single as TextBlock).text, 'recent q');
      expect((history[3].content.single as TextBlock).text, 'recent a');
    });

    test('preserveRecent splits on a human-turn boundary, never a tool pair',
        () async {
      // A tool-using turn sits between two human turns. A naive "last N
      // messages" split at len-2 would start the suffix on the tool_result
      // (index 4), leaving its tool_use summarized away → a dangling
      // tool_result the provider rejects. preserveRecent=1 must cut at the
      // 'q2' human turn (index 2) so the whole tool exchange stays together.
      final provider = FakeProvider([
        [
          const TextDelta('summary'),
          const MessageComplete(
              content: [TextBlock('summary')], stopReason: 'end_turn'),
        ],
      ]);
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('q1')]),
        const Message(role: Role.assistant, content: [TextBlock('a1')]),
        const Message(role: Role.user, content: [TextBlock('q2')]),
        const Message(role: Role.assistant, content: [
          TextBlock('let me check'),
          ToolUseBlock(id: 't1', name: 'read', input: {}),
        ]),
        const Message(role: Role.user, content: [
          ToolResultBlock(toolUseId: 't1', content: 'file contents'),
        ]),
        const Message(role: Role.assistant, content: [TextBlock('a2')]),
      ];

      final compacted = await agent.compact(history, preserveRecent: 1);

      expect(compacted, isTrue);
      // [summary-u, summary-a, q2, tool_use, tool_result, a2] — the tool pair
      // is intact in the suffix, nothing dangling.
      expect(history, hasLength(6));
      expect((history[2].content.single as TextBlock).text, 'q2');
      expect(
          history.any((m) => m.content.any((b) => b is ToolUseBlock)), isTrue);
      expect(history.any((m) => m.content.any((b) => b is ToolResultBlock)),
          isTrue);
    });

    test(
        'preserveRecent is a no-op when there are too few human turns to split',
        () async {
      // One human turn → can't keep one AND summarize a prefix.
      final provider = FakeProvider([[]]); // never invoked
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('only q')]),
        const Message(role: Role.assistant, content: [TextBlock('only a')]),
      ];

      final compacted = await agent.compact(history, preserveRecent: 1);

      expect(compacted, isFalse);
      expect(history, hasLength(2)); // unchanged
    });

    test(
        'preserveRecentMessages splits on an assistant boundary, never a tool pair',
        () async {
      // Mid-turn shape: one human input followed by tool exchanges. The
      // message-boundary mode must summarize the older prefix and keep the
      // trailing exchanges intact — every tool_result still next to its
      // tool_use.
      final provider = FakeProvider([
        [
          const TextDelta('summary'),
          const MessageComplete(
              content: [TextBlock('summary')], stopReason: 'end_turn'),
        ],
      ]);
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('do the task')]),
        const Message(role: Role.assistant, content: [
          TextBlock('checking 1'),
          ToolUseBlock(id: 't1', name: 'read', input: {}),
        ]),
        const Message(role: Role.user, content: [
          ToolResultBlock(toolUseId: 't1', content: 'file one'),
        ]),
        const Message(role: Role.assistant, content: [
          TextBlock('checking 2'),
          ToolUseBlock(id: 't2', name: 'read', input: {}),
        ]),
        const Message(role: Role.user, content: [
          ToolResultBlock(toolUseId: 't2', content: 'file two'),
        ]),
        const Message(role: Role.assistant, content: [
          TextBlock('checking 3'),
          ToolUseBlock(id: 't3', name: 'read', input: {}),
        ]),
        const Message(role: Role.user, content: [
          ToolResultBlock(toolUseId: 't3', content: 'file three'),
        ]),
      ];

      final compacted = await agent.compact(history, preserveRecentMessages: 4);

      expect(compacted, isTrue);
      // [summary-u, summary-a, a(t2), u(t2), a(t3), u(t3)] — the first
      // exchange was summarized away, the kept suffix starts on an assistant
      // message, and t2/t3 pairs are intact.
      expect(history, hasLength(6));
      expect(history[2].role, Role.assistant);
      final useIds = history
          .expand((m) => m.content.whereType<ToolUseBlock>())
          .map((b) => b.id)
          .toSet();
      final resultIds = history
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .map((b) => b.toolUseId)
          .toSet();
      expect(useIds, {'t2', 't3'});
      expect(resultIds, {'t2', 't3'}); // no dangling tool_result
    });

    test(
        'preserveRecentMessages is a no-op when the whole history is the recent exchange',
        () async {
      // Fewer messages than keep (plus the splittable-prefix floor) → nothing
      // to summarize without cutting into the live tool exchange.
      final provider = FakeProvider([[]]); // never invoked
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('q')]),
        const Message(role: Role.assistant, content: [
          ToolUseBlock(id: 't1', name: 'read', input: {}),
        ]),
        const Message(role: Role.user, content: [
          ToolResultBlock(toolUseId: 't1', content: 'big result'),
        ]),
      ];

      final compacted = await agent.compact(history, preserveRecentMessages: 6);

      expect(compacted, isFalse);
      expect(history, hasLength(3)); // unchanged
    });
  });

  group('Agent.run mid-turn auto-compact', () {
    // Tool-result payload sized against a 2000-token threshold: 20k chars
    // estimates to ~5k tokens (bytes/4), enough to trip it.
    final String big = 'x' * 20000;

    List<StreamEvent> toolUse(String id) => [
          MessageComplete(content: [
            ToolUseBlock(id: id, name: 'big', input: const {}),
          ], stopReason: 'tool_use'),
        ];

    /// A tool-use round that also reports [usage], so the turn's cumulative
    /// spend (the [Agent] budget counts every round trip's input+output) can be
    /// driven from a script.
    List<StreamEvent> toolUseWithUsage(String id, TokenUsage usage) => [
          MessageComplete(content: [
            ToolUseBlock(id: id, name: 'big', input: const {}),
          ], stopReason: 'tool_use', usage: usage),
        ];

    List<StreamEvent> text(String t) => [
          MessageComplete(content: [TextBlock(t)], stopReason: 'end_turn'),
        ];

    List<StreamEvent> summary() => [
          const TextDelta('progress summary'),
          const MessageComplete(
              content: [TextBlock('progress summary')], stopReason: 'end_turn'),
        ];

    Agent compactingAgent(FakeProvider provider,
        {FakeToolHandler? handler,
        FakeAgentSink? sink,
        int threshold = 2000,
        int keepMessages = 2}) {
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('big', handler ?? (_) => ToolResult(big)),
        ]),
        sink: sink ?? FakeAgentSink(),
        policy: PermissionPolicy(defaults: {'big': PermissionDecision.allow}),
      );
      agent
        ..autoCompactThreshold = threshold
        ..autoCompactKeepMessages = keepMessages;
      return agent;
    }

    test('compacts in place when the estimated input crosses the threshold',
        () async {
      // Round 1's result is small so the turn starts normally; round 2's big
      // result pushes the next request's estimate over the threshold, so
      // before round 3 the agent summarizes (call index 2), keeping the live
      // tool exchange verbatim, and finishes against the compacted history.
      var calls = 0;
      final agent = compactingAgent(
        FakeProvider([
          toolUse('t1'),
          toolUse('t2'),
          summary(),
          text('all done'),
        ]),
        handler: (_) => ToolResult(calls++ == 0 ? 'small' : big),
      );

      await agent.run(history: <Message>[], userInput: 'go');
      final provider = (agent.provider as FakeProvider);

      expect(provider.calls, hasLength(4));
      // Call 2 is the compaction request: the compact system prompt, and a
      // summary instruction as its last message.
      expect(provider.calls[2].system, isNot('sys'));
      expect(
        provider.calls[2].messages.any((m) => m.content.any((b) =>
            b is TextBlock &&
            b.text.contains('Summarize the conversation above'))),
        isTrue,
      );
      // The post-compaction turn request starts from the summary exchange…
      final lastCall = provider.calls[3];
      expect(
        lastCall.messages.any((m) => m.content.any((b) =>
            b is TextBlock && b.text.contains('Prior conversation summary'))),
        isTrue,
      );
      // …but the in-flight tool result survived verbatim in the suffix.
      expect(
        lastCall.messages.any((m) =>
            m.content.any((b) => b is ToolResultBlock && b.content == big)),
        isTrue,
      );
    });

    test('never compacts when the threshold is 0 (engine default off)',
        () async {
      final provider = FakeProvider([
        toolUse('t1'),
        text('done without compacting'),
      ]);
      final agent = compactingAgent(provider)..autoCompactThreshold = 0;

      await agent.run(history: <Message>[], userInput: 'go');

      expect(provider.calls, hasLength(2));
      expect(provider.calls.every((c) => c.system == 'sys'), isTrue);
    });

    test('a failed compaction is not retried on every step', () async {
      // Every tool result is big. The first splittable history arrives at
      // step 2 (5 messages: input + two exchanges); each compact attempt then
      // yields an empty stream → summary fails → the agent keeps working
      // un-compacted. With the 3-step attempt gate, attempts land on steps 2
      // and 5 → exactly 2 compact requests, not one per step.
      final provider = FakeProvider([
        toolUse('t0'),
        toolUse('t1'),
        const [], // compact attempt at step 2: empty stream → failure
        toolUse('t2'),
        toolUse('t3'),
        toolUse('t4'),
        const [], // compact attempt at step 5
        toolUse('t5'),
        text('done'),
      ]);
      final agent = compactingAgent(provider);

      await agent.run(history: <Message>[], userInput: 'go');

      final compactCalls = provider.calls
          .where((c) => c.messages.any((m) => m.content.any((b) =>
              b is TextBlock &&
              b.text.contains('Summarize the conversation above'))))
          .length;
      expect(compactCalls, 2);
      // The turn still finished normally.
      expect(agent.abortedReason, isNull);
    });

    test(
        'SPEND trigger fires when cumulative tokens cross 50% of per-turn limit',
        () async {
      // The size trigger (estimate > threshold) must NOT fire — only the spend
      // trigger (turnTotal >= perTurn/2 AND estimate > threshold/2). So the
      // estimate has to land in (threshold/2, threshold]: small results keep
      // it low for round 1, then one medium result lifts it over the floor.
      //
      // Usage is 30/round against perTurnLimit 100: after round 2 the turn
      // has spent 60 — past 50% (50) but still under the full limit, so the
      // turn is not budget-aborted and the SPEND check gets to run.
      final medium = 'x' * 2500; // ~625 est. tokens: above the 500 floor
      final provider = FakeProvider([
        toolUseWithUsage(
            't1', const TokenUsage(inputTokens: 15, outputTokens: 15)),
        toolUseWithUsage(
            't2', const TokenUsage(inputTokens: 15, outputTokens: 15)),
        summary(), // the spend-triggered compaction
        text('all done'),
      ]);
      var calls = 0;
      final agent = compactingAgent(
        provider,
        handler: (_) => ToolResult(calls++ == 0 ? 'small' : medium),
        threshold:
            1000, // floor = 500; the medium result lifts estimate to ~640
        keepMessages: 2,
      );
      agent.budget = const TokenBudget(perTurnLimit: 100);

      await agent.run(history: <Message>[], userInput: 'go');

      // Step 2 sees turnTotal 60 (>= 50% of 100) with the medium result in
      // history (estimate ~640: over the 500 floor, under the 1000 size
      // threshold) → SPEND-only compaction: exactly one summary request.
      expect(provider.calls, hasLength(4));
      expect(
        provider.calls
            .where((c) => c.messages.any((m) => m.content.any((b) =>
                b is TextBlock &&
                b.text.contains('Summarize the conversation above'))))
            .length,
        1,
      );
      // The compaction notice names the spend reason (the size path stays quiet).
      expect(
        (agent.sink as FakeAgentSink)
            .notices
            .any((n) => n.message.contains('crossed 50%')),
        isTrue,
        reason: 'the spend trigger is announced, the size trigger is silent',
      );
      expect(agent.abortedReason, isNull,
          reason: '60 spent of 100 allowed — the turn must complete');
    });

    test(
        'FLOOR holds: no compaction when spend past 50% but estimate below floor',
        () async {
      // Spend crosses 50% (usage 30/round against a limit of 100 → 60 after
      // round 2) but the payloads stay tiny, so the estimate never reaches
      // the 500 floor — the floor check is what blocks compaction here, not
      // absent spend.
      final sink = FakeAgentSink();
      final agent = compactingAgent(
        FakeProvider([
          toolUseWithUsage(
              't1', const TokenUsage(inputTokens: 15, outputTokens: 15)),
          toolUseWithUsage(
              't2', const TokenUsage(inputTokens: 15, outputTokens: 15)),
          text('done'),
        ]),
        handler: (_) => ToolResult('small'),
        sink: sink,
        threshold: 1000, // floor = 500; 'small' results never reach it
        keepMessages: 2,
      );
      agent.budget = const TokenBudget(perTurnLimit: 100);

      await agent.run(history: <Message>[], userInput: 'go');

      final provider = agent.provider as FakeProvider;
      expect(provider.calls.where((c) => c.system != 'sys'), isEmpty,
          reason: 'spend crossed 50% but the estimate stayed below the floor');
      expect(agent.abortedReason, isNull, reason: '60 of 100 spent');
    });

    test('threshold 0 disables the spend trigger too', () async {
      // When threshold is 0, auto-compact is disabled entirely — including
      // the spend trigger — and the cumulative cap still protects on its
      // own: 2 tokens recorded against a limit of 1 aborts the turn.
      final sink = FakeAgentSink();
      final agent = compactingAgent(
        FakeProvider([
          toolUseWithUsage(
              't1', const TokenUsage(inputTokens: 2, outputTokens: 0)),
        ]),
        handler: (_) => ToolResult('small'),
        sink: sink,
        threshold: 0, // disable
        keepMessages: 2,
      );
      agent.budget = const TokenBudget(perTurnLimit: 1);

      await agent.run(history: <Message>[], userInput: 'go');

      final provider = agent.provider as FakeProvider;
      expect(provider.calls.where((c) => c.system != 'sys'), isEmpty,
          reason: 'no compaction request may leave the wire at threshold 0');
      expect(agent.abortedReason, contains('per-turn'),
          reason: 'the budget cap is the backstop that stays on');
    });

    test('no perTurnLimit makes spend trigger inert', () async {
      // Usage IS recorded (spend accumulates), but with no per-turn limit
      // there is no fraction to cross — the spend trigger is inert and only
      // the size trigger could fire, which these small payloads never do.
      final sink = FakeAgentSink();
      final agent = compactingAgent(
        FakeProvider([
          toolUseWithUsage(
              't1', const TokenUsage(inputTokens: 15, outputTokens: 15)),
          text('done'),
        ]),
        handler: (_) => ToolResult('small'),
        sink: sink,
        threshold: 2000,
        keepMessages: 2,
      );
      // No caps at all: spend totals advance but can never cross a limit.
      agent.budget = const TokenBudget();

      await agent.run(history: <Message>[], userInput: 'go');

      final provider = agent.provider as FakeProvider;
      expect(provider.calls.every((c) => c.system == 'sys'), isTrue,
          reason: 'accumulating spend without a cap must not compact');
    });
  });

  group('Agent.run result verifier (#22a)', () {
    List<StreamEvent> editUse(String id) => [
          MessageComplete(content: [
            ToolUseBlock(id: id, name: 'edit', input: {'filePath': 'a.dart'}),
          ], stopReason: 'tool_use'),
        ];

    List<StreamEvent> text(String t) => [
          MessageComplete(content: [TextBlock(t)], stopReason: 'end_turn'),
        ];

    Agent editAgent(FakeProvider provider, _VerifierScript script) => _agent(
          provider: provider,
          tools: ToolRegistry([
            FakeTool('edit', (_) => ToolResult('applied')),
          ]),
          sink: FakeAgentSink(),
          policy:
              PermissionPolicy(defaults: {'edit': PermissionDecision.allow}),
          resultVerifier: script.call,
        );

    ToolResultBlock toolResult(List<Message> history) =>
        history.lastWhere((m) => m.role == Role.user).content.single
            as ToolResultBlock;

    test('a non-null verdict is appended to the tool result the model reads',
        () async {
      final script = _VerifierScript()
        ..verdict = (tool, input) =>
            '[analyze] a.dart: 1 error(s) — fix before continuing:\n'
            '  a.dart:3:5 some_error';
      final agent = editAgent(
        FakeProvider([
          editUse('t1'),
          text('fixed it'),
        ]),
        script,
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'edit a.dart');

      expect(script.calls, ['edit'],
          reason: 'the verifier fires once, on the successful edit');
      final result = toolResult(history);
      expect(result.content, startsWith('applied'),
          reason: 'the tool content stays intact, the verdict appends');
      expect(result.content, contains('[analyze] a.dart: 1 error(s)'));
      expect(result.content, contains('a.dart:3:5 some_error'));
      expect(result.isError, isFalse,
          reason: 'the edit succeeded; the verdict is advisory, not an error');
      // The next request really carried the appended block.
      expect((agent.provider as FakeProvider).calls, hasLength(2));
    });

    test('the verifier is skipped on an error tool result', () async {
      final script = _VerifierScript()
        ..verdict = (tool, input) => 'should not appear';
      final agent = _agent(
        provider: FakeProvider([
          editUse('t1'),
          text('recovered'),
        ]),
        tools: ToolRegistry([
          FakeTool('edit', (_) => ToolResult.error('file not found')),
        ]),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(defaults: {'edit': PermissionDecision.allow}),
        resultVerifier: script.call,
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'edit a.dart');

      expect(script.calls, isEmpty,
          reason: 'an error result ships as-is; no post-edit gate on failure');
      final result = toolResult(history);
      expect(result.isError, isTrue);
      expect(result.content, 'file not found');
    });

    test('a throwing verifier leaves the result unchanged and the turn lives',
        () async {
      final script = _VerifierScript()
        ..verdict = (tool, input) => throw StateError('boom');
      final agent = editAgent(
        FakeProvider([
          editUse('t1'),
          text('carried on'),
        ]),
        script,
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'edit a.dart');

      expect(script.calls, ['edit'],
          reason: 'the verifier ran — and its crash was contained');
      final result = toolResult(history);
      expect(result.content, 'applied',
          reason: 'the crash must not corrupt or lose the tool content');
      expect(agent.abortedReason, isNull);
      expect((agent.provider as FakeProvider).calls, hasLength(2),
          reason: 'the turn continued to the second model call');
    });

    test('a null verifier leaves the result byte-identical', () async {
      final agent = editAgent(
        FakeProvider([
          editUse('t1'),
          text('done'),
        ]),
        _VerifierScript(),
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'edit a.dart');

      final result = toolResult(history);
      expect(result.content, 'applied');
      expect(result.isError, isFalse);
    });
  });

  group('Agent history observers (#25 write-through persistence)', () {
    List<StreamEvent> toolUse(String id) => [
          ToolCallStart(id: id, name: 'gate'),
          MessageComplete(
            content: [
              ToolUseBlock(id: id, name: 'gate', input: const {}),
            ],
            stopReason: 'tool_use',
          ),
        ];

    List<StreamEvent> text(String t) => [
          TextDelta(t),
          MessageComplete(content: [TextBlock(t)], stopReason: 'end_turn'),
        ];

    /// An agent whose tool parks on [gate] until released — lets the test
    /// freeze the turn mid-flight and assert what the observers have already
    /// seen (the write-through ordering guarantee).
    Agent gatedAgent(FakeProvider provider, Completer<void> gate,
        {HistoryAppendObserver? onAppend, HistoryReplaceObserver? onReplace}) {
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('gate', (_) async {
            await gate.future;
            return ToolResult('gate passed');
          }),
        ]),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(defaults: {'gate': PermissionDecision.allow}),
        onHistoryAppend: onAppend,
        onHistoryReplace: onReplace,
      );
      return agent;
    }

    test('append observer fires in order for user, assistant, tool results',
        () async {
      final observed = <Role>[];
      final gate = Completer<void>();
      final agent = gatedAgent(
        FakeProvider([
          toolUse('t1'),
          text('finished'),
        ]),
        gate,
        onAppend: (m) async {
          observed.add(m.role);
        },
      );

      final run = agent.run(history: <Message>[], userInput: 'go');
      // The turn is parked inside the tool; the user message and the
      // assistant tool_use completion have both already been observed —
      // write-through, not end-of-turn.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(observed, [Role.user, Role.assistant]);

      gate.complete();
      await run;

      // The tool-result batch lands before the final assistant text.
      expect(observed, [Role.user, Role.assistant, Role.user, Role.assistant]);
    });

    test('run does not return while an append observer is still in flight',
        () async {
      // The observer holds its write open until the test releases it. If the
      // agent fired-and-forgot, run() could finish (and a caller tear the
      // store down) while the last write is still pending.
      final observerReleased = Completer<void>();
      var observerFinished = false;
      final gate = Completer<void>();
      final agent = gatedAgent(
        FakeProvider([
          toolUse('t1'),
          text('finished'),
        ]),
        gate,
        onAppend: (m) async {
          await observerReleased.future;
          observerFinished = true;
        },
      );

      final run = agent.run(history: <Message>[], userInput: 'go');
      // Give the turn time to reach the final append (the assistant text)…
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // …then let the observer finish and the turn unwind.
      observerReleased.complete();
      gate.complete();
      await run;

      expect(observerFinished, isTrue,
          reason: 'the awaited observer completed before run() returned');
    });

    test('a throwing append observer is contained and the turn completes',
        () async {
      final gate = Completer<void>();
      final agent = gatedAgent(
        FakeProvider([
          toolUse('t1'),
          text('survived'),
        ]),
        gate,
        onAppend: (m) async => throw StateError('recorder exploded'),
      );

      final runFuture = agent.run(history: <Message>[], userInput: 'go');
      gate.complete(); // let the gated tool through
      await runFuture;

      expect(agent.abortedReason, isNull,
          reason: 'a broken observer must degrade to "not persisted"');
      expect((agent.sink as FakeAgentSink).texts, ['survived']);
    });

    test('compact fires replace once with the final post-compact list',
        () async {
      var replaces = 0;
      List<Message>? replacedWith;
      final provider = FakeProvider([
        [
          const TextDelta('the gist'),
          const MessageComplete(
              content: [TextBlock('the gist')], stopReason: 'end_turn'),
        ],
      ]);
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        onHistoryAppend: (m) async {
          // Not expected: compact rebuilds via replace, not append.
        },
        onHistoryReplace: (messages) async {
          replaces++;
          replacedWith = messages; // keep the identity: replace passes the list
        },
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('old q')]),
        const Message(role: Role.assistant, content: [TextBlock('old a')]),
        const Message(role: Role.user, content: [TextBlock('recent q')]),
        const Message(role: Role.assistant, content: [TextBlock('recent a')]),
      ];

      final compacted = await agent.compact(history, preserveRecent: 1);

      expect(compacted, isTrue);
      // The rewrite is observed as ONE replace carrying the final list —
      // the rebuilt summary exchange plus the kept suffix — and nothing else.
      expect(replaces, 1);
      expect(replacedWith, same(history));
      expect((replacedWith![0].content.single as TextBlock).text,
          contains('Prior conversation summary:\n\nthe gist'));
      expect((replacedWith![2].content.single as TextBlock).text, 'recent q');
      expect((replacedWith![3].content.single as TextBlock).text, 'recent a');
    });

    test('a throwing replace observer is contained and compact still succeeds',
        () async {
      final provider = FakeProvider([
        [
          const TextDelta('summary'),
          const MessageComplete(
              content: [TextBlock('summary')], stopReason: 'end_turn'),
        ],
      ]);
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        onHistoryReplace: (messages) async => throw StateError('boom'),
      );
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('old q')]),
        const Message(role: Role.assistant, content: [TextBlock('old a')]),
        const Message(role: Role.user, content: [TextBlock('recent q')]),
        const Message(role: Role.assistant, content: [TextBlock('recent a')]),
      ];

      final compacted = await agent.compact(history, preserveRecent: 1);

      expect(compacted, isTrue,
          reason: 'a broken persistence observer must not fail the compact');
      expect(history, hasLength(4));
    });

    test('null observers leave the turn byte-identical (default off)',
        () async {
      final provider = FakeProvider([
        [
          const TextDelta('plain'),
          const MessageComplete(
              content: [TextBlock('plain')], stopReason: 'end_turn'),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = _agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: sink,
        policy: PermissionPolicy(),
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'go');

      expect(provider.calls, hasLength(1));
      expect(sink.texts, ['plain']);
      // user → assistant — no observer ever fired; byte-identical behavior.
      expect(history, hasLength(2));
      expect(agent.abortedReason, isNull);
    });
  });
}
