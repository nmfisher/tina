import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

/// #29 command retry guard: a tool result that goes nowhere — timeout, empty
/// output, or the byte-identical error of the previous attempt of the SAME
/// command — is an anomaly. Three consecutive anomalies of one signature in
/// ONE turn append an in-band guardrail note to the result and fire exactly
/// one operator notice; a normal result resets the streak; a new turn starts
/// from zero.
void main() {
  // One provider step that calls [toolName] with [input] — the agent executes
  // the tool, appends the result, and comes back for the next step.
  List<StreamEvent> useStep(
          String id, String toolName, Map<String, dynamic> input) =>
      [
        MessageComplete(
          content: [ToolUseBlock(id: id, name: toolName, input: input)],
          stopReason: 'tool_use',
        ),
      ];

  List<StreamEvent> answerStep() => [
        const TextDelta('done'),
        MessageComplete(content: [TextBlock('done')], stopReason: 'end_turn'),
      ];

  /// A provider that issues one tool call per [inputs] entry (unique
  /// tool_use ids), then a final answer — driving exactly that many
  /// executions before the turn ends normally.
  FakeProvider toolLoop(String toolName, List<Map<String, dynamic>> inputs) =>
      FakeProvider([
        for (var i = 0; i < inputs.length; i++)
          useStep('u$i', toolName, inputs[i]),
        answerStep(),
      ]);

  /// The tool_result blocks the model saw, in history order.
  List<ToolResultBlock> resultBlocks(List<Message> history) => [
        for (final m in history)
          if (m.role == Role.user)
            for (final b in m.content)
              if (b is ToolResultBlock) b,
      ];

  /// An agent over one [toolName] tool whose results are popped from
  /// [results] in order (the last repeats if the agent executes more times
  /// than scripted). The per-tool default allow keeps the asker out of the
  /// way; it denies anyway, so an accidental ask shows up as denial content
  /// and fails the expectations loudly.
  Agent agentOver(
    String toolName,
    List<Map<String, dynamic>> inputs,
    List<ToolResult> results,
    FakeAgentSink sink,
  ) {
    var next = 0;
    return Agent(
      provider: toolLoop(toolName, inputs),
      tools: ToolRegistry([
        FakeTool(
          toolName,
          (_) => next < results.length
              ? results[next++]
              : const ToolResult('exhausted'),
        ),
      ]),
      sink: sink,
      policy: PermissionPolicy(defaults: {toolName: PermissionDecision.allow}),
      asker: (_) async => PermissionResponse.denyOnce,
      system: 'sys',
    );
  }

  /// Guardrail trip notices on the sink. The agent has exactly one such
  /// emission per trip — a count above the expected value means a second
  /// channel fired.
  int guardrailNotices(FakeAgentSink sink) => sink.notices
      .where((n) =>
          n.message.contains('consecutive anomalies') &&
          n.kind == NoticeKind.warning)
      .length;

  Future<List<ToolResultBlock>> runTurn(
      Agent agent, List<Message> history) async {
    await agent.run(history: history, userInput: 'go');
    return resultBlocks(history);
  }

  test('anomalySignature normalizes bash whitespace and pins other-tool input',
      () {
    // bash: whitespace runs collapse — these are the same command.
    expect(Agent.anomalySignature('bash', {'command': 'ls -la'}),
        Agent.anomalySignature('bash', {'command': '  ls \t\n -la  '}));
    // bash: different commands stay distinct, and the tool name is in the key.
    expect(Agent.anomalySignature('bash', {'command': 'ls -la'}),
        isNot(Agent.anomalySignature('bash', {'command': 'ls -la /tmp'})));
    expect(Agent.anomalySignature('bash', {'command': 'ls'}),
        isNot(Agent.anomalySignature('ls', {'command': 'ls'})));
    // bash: a missing command falls through raw rather than crashing.
    expect(Agent.anomalySignature('bash', {}), 'bash|null');

    // Other tools: key order must not matter (stable serialization).
    expect(
      Agent.anomalySignature(
          'edit', {'path': 'a.dart', 'old': 'x', 'new': 'y'}),
      Agent.anomalySignature(
          'edit', {'new': 'y', 'old': 'x', 'path': 'a.dart'}),
    );
    // …but different inputs do.
    expect(
      Agent.anomalySignature('edit', {'path': 'a.dart'}),
      isNot(Agent.anomalySignature('edit', {'path': 'b.dart'})),
    );
    // …and values are visibly serialized.
    expect(
        Agent.anomalySignature('read', {'path': 'x'}), contains('"path":"x"'));
  });

  group('Agent.isAnomalousResult (#29)', () {
    test('timeout and empty output are anomalies on their own', () {
      expect(Agent.isAnomalousResult(const ToolResult('x', timedOut: true)),
          isTrue);
      expect(Agent.isAnomalousResult(const ToolResult('', emptyOutput: true)),
          isTrue);
      expect(
          Agent.isAnomalousResult(
              const ToolResult('', emptyOutput: true, isError: true)),
          isTrue);
    });

    test('identical error content is an anomaly; changed content is not', () {
      expect(
          Agent.isAnomalousResult(const ToolResult('boom', isError: true),
              previousContent: 'boom'),
          isTrue);
      expect(
          Agent.isAnomalousResult(
              const ToolResult('boom: permission denied', isError: true),
              previousContent: 'boom: no such file'),
          isFalse,
          reason: 'a changed error means the retry did something');
    });

    test('no previous attempt, success, and null metadata never fire', () {
      // First attempt: nothing to compare an error against yet.
      expect(
          Agent.isAnomalousResult(const ToolResult('boom', isError: true)),
          isFalse);
      // Identical content is only suspicious when the tool ERRORED.
      expect(Agent.isAnomalousResult(const ToolResult('boom'),
          previousContent: 'boom'), isFalse);
      // A metadata-less tool reports neither timeout nor emptiness.
      expect(Agent.isAnomalousResult(const ToolResult(''),
          previousContent: ''), isFalse);
      // Explicit false is as good as null.
      expect(
          Agent.isAnomalousResult(
              const ToolResult('x', timedOut: false, emptyOutput: false)),
          isFalse);
    });
  });

  group('Agent.run command retry guard (#29)', () {
    test('3 consecutive timeout anomalies trip the note once; the 4th '
        're-appends it without a second notice', () async {
      final sink = FakeAgentSink();
      final input = {'path': 'big.log'};
      final timedOut =
          const ToolResult('timed out', isError: true, timedOut: true);
      final agent = agentOver(
        'fake',
        [input, input, input, input],
        [timedOut, timedOut, timedOut, timedOut],
        sink,
      );
      final history = <Message>[];
      final blocks = await runTurn(agent, history);

      expect(blocks, hasLength(4));
      // Attempts 1–2: the raw failure, untouched.
      expect(blocks[0].content, 'timed out');
      expect(blocks[1].content, 'timed out');
      // Attempt 3 (the trip) and 4 (past it): the guardrail line rides the
      // result the model actually reads.
      expect(blocks[2].content, contains('[guardrail]'));
      expect(blocks[2].content, contains('Do not re-run it unchanged'));
      expect(blocks[3].content, contains('[guardrail]'));
      // Exactly ONE operator notice — the crossing, not every repeat.
      expect(guardrailNotices(sink), 1);
      expect(blocks[2].isError, isTrue, reason: 'metadata is preserved');
    });

    test('empty output counts (class b) and trips on the third', () async {
      final sink = FakeAgentSink();
      final input = {'path': 'silent.bin'};
      final silent = const ToolResult('', emptyOutput: true);
      final agent = agentOver(
        'fake',
        [input, input, input],
        [silent, silent, silent],
        sink,
      );
      final blocks = await runTurn(agent, <Message>[]);

      expect(blocks[1].content, isNot(contains('[guardrail]')));
      expect(blocks[2].content, contains('[guardrail]'));
      expect(guardrailNotices(sink), 1);
    });

    test('a byte-identical error (class c) trips on the FOURTH attempt — the '
        'first one only baselines the comparison', () async {
      final sink = FakeAgentSink();
      final input = {'path': 'x'};
      final boom = const ToolResult('boom: no such file', isError: true);
      final agent = agentOver(
        'fake',
        [input, input, input, input],
        [boom, boom, boom, boom],
        sink,
      );
      final blocks = await runTurn(agent, <Message>[]);

      // Attempt 1 has no previous attempt to compare against — no anomaly,
      // so the streak only reaches 3 on attempt 4.
      for (var i = 0; i < 3; i++) {
        expect(blocks[i].content, 'boom: no such file');
      }
      expect(blocks[3].content, contains('[guardrail]'));
      expect(guardrailNotices(sink), 1);
    });

    test('an error whose CONTENT CHANGED between attempts never trips — the '
        'retry is doing something', () async {
      final sink = FakeAgentSink();
      final input = {'path': 'x'};
      final agent = agentOver(
        'fake',
        [input, input, input, input],
        const [
          ToolResult('boom: no such file', isError: true),
          ToolResult('boom: permission denied', isError: true),
          ToolResult('boom: is a directory', isError: true),
          ToolResult('boom: no such file', isError: true),
        ],
        sink,
      );
      final blocks = await runTurn(agent, <Message>[]);

      for (final b in blocks) {
        expect(b.content, isNot(contains('[guardrail]')),
            reason: 'every attempt differed from the one before it');
      }
      expect(guardrailNotices(sink), 0);
    });

    test('a success resets the streak — a later anomaly starts from one',
        () async {
      final sink = FakeAgentSink();
      final input = {'path': 'y'};
      final timedOut =
          const ToolResult('timed out', isError: true, timedOut: true);
      final agent = agentOver(
        'fake',
        [input, input, input, input, input],
        [
          timedOut,
          timedOut,
          timedOut,
          const ToolResult('recovered output'), // the reset
          timedOut,
        ],
        sink,
      );
      final blocks = await runTurn(agent, <Message>[]);

      expect(blocks[2].content, contains('[guardrail]')); // the trip
      expect(blocks[3].content, 'recovered output'); // success, no note
      // Streak restarted: attempt 5 is an anomaly again, but streak 1 only.
      expect(blocks[4].content, 'timed out');
      expect(guardrailNotices(sink), 1);
    });

    test('streaks are per-signature: an anomaly of another command does not '
        'break the first command\u2019s count', () async {
      final sink = FakeAgentSink();
      final a = {'path': 'a.txt'};
      final b = {'path': 'b.txt'};
      final timedOut =
          const ToolResult('timed out', isError: true, timedOut: true);
      final agent = agentOver(
        'fake',
        [a, a, b, a],
        [timedOut, timedOut, timedOut, timedOut],
        sink,
      );
      final blocks = await runTurn(agent, <Message>[]);

      // A, A: A's streak is 2. Then B: B's own streak starts at 1 — it must
      // not reset A's count (only a non-anomalous A result would).
      expect(blocks[2].content, isNot(contains('[guardrail]')));
      // A again: A's THIRD consecutive anomaly — the trip.
      expect(blocks[3].content, contains('[guardrail]'));
      expect(guardrailNotices(sink), 1);
    });

    test('a null-metadata tool never trips on plain output — only the '
        'identical-error class can catch it', () async {
      // Identical SUCCESS results (metadata all null): never an anomaly.
      final okSink = FakeAgentSink();
      final okInput = {'path': 'z'};
      final okAgent = agentOver(
        'fake',
        [okInput, okInput, okInput],
        const [ToolResult('ok'), ToolResult('ok'), ToolResult('ok')],
        okSink,
      );
      for (final b in await runTurn(okAgent, <Message>[])) {
        expect(b.content, isNot(contains('[guardrail]')));
      }
      expect(guardrailNotices(okSink), 0);

      // Identical EMPTY successes: emptyOutput is null (the tool does not
      // measure it), so class (b) must not fire either.
      final emptySink = FakeAgentSink();
      final emptyAgent = agentOver(
        'fake',
        [okInput, okInput, okInput],
        const [ToolResult(''), ToolResult(''), ToolResult('')],
        emptySink,
      );
      for (final b in await runTurn(emptyAgent, <Message>[])) {
        expect(b.content, isNot(contains('[guardrail]')));
      }
      expect(guardrailNotices(emptySink), 0);
    });

    test('a new turn starts from zero — streaks never survive run()', () async {
      final sink = FakeAgentSink();
      final input = {'path': 'loop.log'};
      final timedOut =
          const ToolResult('timed out', isError: true, timedOut: true);
      final agent = Agent(
        provider: FakeProvider([
          // Turn 1: three anomalies (the trip), then the answer.
          useStep('t1-a', 'fake', input),
          useStep('t1-b', 'fake', input),
          useStep('t1-c', 'fake', input),
          answerStep(),
          // Turn 2: one more identical anomaly.
          useStep('t2-a', 'fake', input),
          answerStep(),
        ]),
        tools: ToolRegistry([FakeTool('fake', (_) => timedOut)]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'fake': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'sys',
      );
      final history = <Message>[];

      await agent.run(history: history, userInput: 'go');
      final turn1 = resultBlocks(history);
      expect(turn1, hasLength(3));
      expect(turn1[2].content, contains('[guardrail]'));
      expect(guardrailNotices(sink), 1);

      await agent.run(history: history, userInput: 'again');
      final blocks = resultBlocks(history);
      expect(blocks, hasLength(4));
      // Fresh turn: the same command's streak restarted at 1 — no note.
      expect(blocks[3].content, 'timed out');
      // And the trip notice count is still exactly one.
      expect(guardrailNotices(sink), 1);
    });
  });
}
