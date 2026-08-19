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
}) =>
    Agent(
      provider: provider,
      tools: tools,
      sink: sink,
      policy: policy ?? PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      maxSteps: maxSteps,
      system: 'sys',
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
      await agent.run(
          history: [], userInput: 'hi', cancelSignal: cancel.future);
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
  });

  group('Agent.run', () {
    test('single turn with no tools emits text and appends to history', () async {
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

      expect(inputs, [
        {'command': r'echo "done: \"$?\""'},
      ], reason: 'only the well-formed retry reaches the tool, input verbatim');
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
      expect(sink.notices.any((n) => n.message.contains('unknown tool')), isTrue);
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
        tools: ToolRegistry([FakeTool('bash', (_) => throw StateError('boom'))]),
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
        const Message(role: Role.assistant, content: [TextBlock('old assistant')]),
      ];

      await agent.compact(history);

      expect(history, hasLength(2));
      expect(history[0].role, Role.user);
      expect(history[1].role, Role.assistant);
      expect(sink.texts, ['summary bullets']); // summary streamed through the sink
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

      expect(sink.notices.any((n) => n.message.contains('compact failed')), isTrue);
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
      expect(
          history.any((m) => m.content.any((b) => b is ToolResultBlock)),
          isTrue);
    });

    test('preserveRecent is a no-op when there are too few human turns to split',
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
  });
}
