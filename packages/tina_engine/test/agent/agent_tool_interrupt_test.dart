import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/agent_test_fixtures.dart' show answerEvents;
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';

/// #31 leg 3 — the operator interrupt: [Agent.run]'s `toolInterruptSignal`.
///
/// Contract under test (docs/proposals/runaway_command_guardrails.md §3 C):
///   * the signal is consulted ONLY around tool execution — provider stream
///     phases are never torn down mid-token;
///   * the batch in flight when it fires completes WHOLE: every tool_use
///     gets its tool_result, appended to history in order;
///   * the in-flight call's result is prefixed with the operator line
///     (whether or not a kill landed — deterministic and honest), its own
///     isError preserved; the interrupt rides the tool's EXISTING cancel
///     seam while a call is executing (the bash kill path);
///   * the remaining calls of the batch stub as `skipped: operator
///     interrupt` errors, without executing;
///   * the turn then ends CLEANLY: run returns normally, no `[cancelled]`
///     notice, abortedKind none, no next provider step;
///   * an interrupt that fires BEFORE a batch makes that batch begin
///     already-interrupted: its first call still executes (and is prefixed),
///     the rest stub;
///   * the signal is per-run: callers must hand each run a fresh future
///     (e.g. a per-turn completer), never one from an earlier turn.

/// A tool whose execute parks on the next gate in [gates] (one per call, so
/// the test controls exactly when each call returns) and then yields a fixed
/// result. Records, per call, whether the cancel/interrupt signal it was
/// handed had ALREADY fired at the moment execute resumed — `null` when no
/// signal was passed at all. This is the assertion seam for "the interrupt
/// rides the tool's existing cancel seam" (the bash kill path in production).
class GatedTool implements Tool {
  final List<Completer<void>> gates;
  int calls = 0;
  final List<bool?> sawSignalFired = [];

  @override
  final ToolSchema schema;

  GatedTool(String name, this.gates)
      : schema = ToolSchema(
          name: name,
          description: 'parks on a gate',
          inputSchema: const {'type': 'object', 'properties': {}},
        );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final i = calls++;
    await gates[i < gates.length ? i : gates.length - 1].future;
    if (cancelSignal == null) {
      sawSignalFired.add(null);
    } else {
      var fired = false;
      cancelSignal.then((_) => fired = true);
      // A completed future delivers its callbacks in microtasks, before this
      // zero-duration timer; a pending one never sets [fired].
      await Future<void>.delayed(Duration.zero);
      sawSignalFired.add(fired);
    }
    return const ToolResult('slow-ok');
  }
}

/// Pump the event loop until [cond] holds (bounded), so tests assert on
/// reached states rather than guessing microtask counts.
Future<void> waitFor(bool Function() cond, String reason) async {
  for (var i = 0; i < 500 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  if (!cond()) fail('timed out waiting: $reason');
}

ToolResultBlock resultOf(Message m, int i) => m.content[i] as ToolResultBlock;

Message lastUserMessage(List<Message> history) =>
    history.lastWhere((m) => m.role == Role.user);

Agent agentWith({
  required LlmProvider provider,
  required List<Tool> tools,
  required FakeAgentSink sink,
}) =>
    Agent(
      provider: provider,
      tools: ToolRegistry(tools),
      sink: sink,
      policy: PermissionPolicy(
          defaults: {
            for (final t in tools) t.schema.name: PermissionDecision.allow
          }),
      asker: (_) async => PermissionResponse.denyOnce,
      system: 'sys',
    );

void main() {
  test('mid-batch interrupt: batch completes whole, in-flight result '
      'prefixed, rest stubbed, turn ends cleanly', () async {
    final interrupt = Completer<void>();
    final gates = [Completer<void>(), Completer<void>(), Completer<void>()];
    final tool = GatedTool('slow', gates);
    // One provider step that emits THREE tool calls, then an answer that
    // must never stream: the turn ends after the interrupted batch.
    final provider = FakeProvider([
      [
        const MessageComplete(
          content: [
            ToolUseBlock(id: 'c1', name: 'slow', input: {'n': 1}),
            ToolUseBlock(id: 'c2', name: 'slow', input: {'n': 2}),
            ToolUseBlock(id: 'c3', name: 'slow', input: {'n': 3}),
          ],
          stopReason: 'tool_use',
        ),
      ],
      answerEvents('AFTER BATCH — MUST NOT RUN'),
    ]);
    final sink = FakeAgentSink();
    final agent = agentWith(provider: provider, tools: [tool], sink: sink);
    final history = <Message>[];

    final run = agent.run(
      history: history,
      userInput: 'go',
      toolInterruptSignal: interrupt.future,
    );
    await waitFor(() => sink.toolStarts.length == 1, 'c1 executing');
    // The operator interrupt lands WHILE c1 is in flight; then the in-flight
    // call returns (in production the kill path would have ended it sooner —
    // the prefix is deterministic either way).
    interrupt.complete();
    gates[0].complete();
    await run.timeout(const Duration(seconds: 5));

    // The interrupt rode the tool's EXISTING cancel seam (the bash kill
    // path): the in-flight call received the interrupt future as its cancel
    // signal and saw it fire.
    expect(tool.sawSignalFired, [true],
        reason: 'the in-flight call receives the pending interrupt future '
            'as its cancel signal');
    expect(sink.toolStarts, hasLength(1),
        reason: 'c2/c3 never start — they stub without executing');
    expect(provider.calls, hasLength(1),
        reason: 'the turn ends after the batch — no next provider step');

    // Whole-batch invariant: one tool_result per tool_use, in order.
    final batch = lastUserMessage(history);
    expect(batch.content, hasLength(3));
    expect(resultOf(batch, 0).toolUseId, 'c1');
    expect(resultOf(batch, 0).content, '$kOperatorInterruptedLine\nslow-ok',
        reason: 'the in-flight call keeps its own result under the '
            'operator line');
    expect(resultOf(batch, 0).isError, isFalse,
        reason: "isError reflects the tool's own result, unchanged");
    expect(resultOf(batch, 1).toolUseId, 'c2');
    expect(resultOf(batch, 1).content, kOperatorInterruptedStub);
    expect(resultOf(batch, 1).isError, isTrue);
    expect(resultOf(batch, 2).toolUseId, 'c3');
    expect(resultOf(batch, 2).content, kOperatorInterruptedStub);
    expect(resultOf(batch, 2).isError, isTrue);

    // Clean end: not a cancel, no abort.
    expect(agent.abortedKind, AbortedKind.none);
    expect(agent.abortedReason, isNull);
    final noticeText = sink.notices.map((n) => n.message).join('\n');
    expect(noticeText, isNot(contains('[cancelled]')));
    expect(
        sink.notices
            .where((n) => n.message.contains(kOperatorInterruptedLine))
            .length,
        1,
        reason: 'the operator sees the interrupt notice, exactly once');
  });

  test('provider stream phases are NOT interruptible: a fired signal with '
      'no tools in flight changes nothing', () async {
    final interrupt = Completer<void>()..complete(); // already fired
    final provider = FakeProvider([
      [
        const TextDelta('the whole answer'),
        const MessageComplete(
          content: [TextBlock('the whole answer')],
          stopReason: 'end_turn',
        ),
      ],
    ]);
    final sink = FakeAgentSink();
    final agent = agentWith(provider: provider, tools: const [], sink: sink);
    final history = <Message>[];

    await agent.run(
      history: history,
      userInput: 'go',
      toolInterruptSignal: interrupt.future,
    ).timeout(const Duration(seconds: 5));

    expect(sink.texts.join(), contains('the whole answer'),
        reason: 'the stream ran to completion — never torn down');
    expect(provider.calls, hasLength(1));
    expect(agent.abortedKind, AbortedKind.none);
    expect(
        sink.notices.map((n) => n.message).join('\n'),
        isNot(contains(kOperatorInterruptedLine)),
        reason: 'no tool batch ever started — the interrupt had nothing '
            'to interrupt');
  });

  test('pre-batch fire: the next batch begins already-interrupted — first '
      'call still executes and is prefixed, the rest stub', () async {
    final interrupt = Completer<void>()..complete(); // fired before any batch
    final gate = Completer<void>();
    final tool = GatedTool('slow', [gate]);
    final provider = FakeProvider([
      [
        const MessageComplete(
          content: [
            ToolUseBlock(id: 'c1', name: 'slow', input: {'n': 1}),
            ToolUseBlock(id: 'c2', name: 'slow', input: {'n': 2}),
          ],
          stopReason: 'tool_use',
        ),
      ],
      answerEvents('AFTER BATCH — MUST NOT RUN'),
    ]);
    final sink = FakeAgentSink();
    final agent = agentWith(provider: provider, tools: [tool], sink: sink);
    final history = <Message>[];

    final run = agent.run(
      history: history,
      userInput: 'go',
      toolInterruptSignal: interrupt.future,
    );
    await waitFor(() => sink.toolStarts.length == 1, 'first call executing');
    gate.complete();
    await run.timeout(const Duration(seconds: 5));

    expect(sink.toolStarts, hasLength(1),
        reason: 'the first call of the already-interrupted batch still runs');
    // The call is NOT handed the already-fired interrupt (that would kill it
    // before it could produce the honest result the prefix lands over); the
    // run's own cancel slot passes through — null here.
    expect(tool.sawSignalFired, [null],
        reason: 'an already-fired interrupt does not instant-kill the '
            'first call; the prefix lands over its real result');
    final batch = lastUserMessage(history);
    expect(batch.content, hasLength(2));
    expect(resultOf(batch, 0).toolUseId, 'c1');
    expect(resultOf(batch, 0).content, '$kOperatorInterruptedLine\nslow-ok');
    expect(resultOf(batch, 0).isError, isFalse);
    expect(resultOf(batch, 1).toolUseId, 'c2');
    expect(resultOf(batch, 1).content, kOperatorInterruptedStub);
    expect(resultOf(batch, 1).isError, isTrue);
    expect(provider.calls, hasLength(1));
    expect(agent.abortedKind, AbortedKind.none);
    expect(
        sink.notices.map((n) => n.message).join('\n'),
        isNot(contains('[cancelled]')));
  });

  test('the signal is per-run: a stale completed future interrupts the next '
      "run's first batch — callers must hand each run a fresh one", () async {
    final interrupt = Completer<void>();
    final gate = Completer<void>();
    final tool = GatedTool('slow', [gate]);
    final provider = FakeProvider([
      answerEvents('first answer'),
      [
        const MessageComplete(
          content: [
            ToolUseBlock(id: 'c1', name: 'slow', input: {'n': 1}),
            ToolUseBlock(id: 'c2', name: 'slow', input: {'n': 2}),
          ],
          stopReason: 'tool_use',
        ),
      ],
    ]);
    final sink = FakeAgentSink();
    final agent = agentWith(provider: provider, tools: [tool], sink: sink);

    // Run 1: fresh, never-fired signal — an ordinary turn.
    await agent.run(
      history: <Message>[],
      userInput: 'first',
      toolInterruptSignal: interrupt.future,
    ).timeout(const Duration(seconds: 5));
    expect(provider.calls, hasLength(1));
    expect(sink.texts.join(), contains('first answer'));
    expect(sink.notices.map((n) => n.message).join('\n'),
        isNot(contains(kOperatorInterruptedLine)));

    // Run 2 reuses the SAME future — now completed. Documented hazard: the
    // agent does not silently swallow a stale signal; run 2's first batch
    // begins already-interrupted.
    interrupt.complete();
    final history2 = <Message>[];
    final run2 = agent.run(
      history: history2,
      userInput: 'second',
      toolInterruptSignal: interrupt.future,
    );
    await waitFor(() => sink.toolStarts.length == 1, 'run 2 first call');
    gate.complete();
    await run2.timeout(const Duration(seconds: 5));

    expect(tool.sawSignalFired, [null],
        reason: 'run 2 batch began already-interrupted (no instant kill)');
    final batch = lastUserMessage(history2);
    expect(batch.content, hasLength(2));
    expect(resultOf(batch, 0).content, '$kOperatorInterruptedLine\nslow-ok');
    expect(resultOf(batch, 1).content, kOperatorInterruptedStub);
    expect(resultOf(batch, 1).isError, isTrue);
    expect(provider.calls, hasLength(2),
        reason: 'run 2 ended after its first batch');
    expect(agent.abortedKind, AbortedKind.none);
  });
}
