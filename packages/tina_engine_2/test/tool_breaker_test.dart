import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

final class BreakerTool extends AgentPlugin {
  @override
  String get id => 'test/breaker';
  @override
  List<ToolSchema> get tools =>
      const [ToolSchema(name: 'example', description: '', inputSchema: {})];
}

List<ToolResultBlock> toolResults(AgentLoop loop) => loop.log
    .whereType<MessageAppendedEntry>()
    .expand((entry) => entry.message.content)
    .whereType<ToolResultBlock>()
    .toList();

/// One failing call per scripted reply, so each round-trip is one attempt.
List<StreamEvent> attempt(String id, {Map<String, Object?> input = const {}}) =>
    scriptedReply('',
        calls: [ToolUseBlock(id: id, name: 'example', input: input)]);

void main() {
  test('a third identical failing call is refused without executing', () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          attempt('c1'),
          attempt('c2'),
          attempt('c3'),
          scriptedReply('done'),
        ]),
        plugins: [BreakerTool()]);
    var executions = 0;
    const failure = 'the task queue is empty';
    loop.registerExecutor('example', (input) async {
      executions++;
      return const ToolResult(failure, isError: true);
    });
    final outcome = await loop.runTurn(const Input('run', id: 't1'));
    expect(outcome.stopReason, StopReason.complete);
    expect(executions, 2); // the third call never ran
    final results = toolResults(loop);
    expect(results, hasLength(3));
    expect(results[0].content, failure);
    expect(results[1].content, failure);
    expect(results[2].isError, isTrue);
    expect(results[2].content, contains('not executed'));
    expect(results[2].content, contains('failed 2 times'));
    expect(results[2].content, contains(failure)); // the quoted last error
  });

  test('changed arguments reset the breaker and the call executes', () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          attempt('c1'),
          attempt('c2'),
          attempt('c3', input: {'x': 1}),
          attempt('c4'), // original arguments again — the streak was replaced
          scriptedReply('done'),
        ]),
        plugins: [BreakerTool()]);
    var executions = 0;
    loop.registerExecutor('example', (input) async {
      executions++;
      return const ToolResult('nope', isError: true);
    });
    final outcome = await loop.runTurn(const Input('run', id: 't1'));
    expect(outcome.stopReason, StopReason.complete);
    expect(executions, 4); // nothing blocked: every call ran
    expect(toolResults(loop).where((r) => r.content.contains('not executed')),
        isEmpty);
  });

  test('retrying a blocked call twice ends the turn with a user notice',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          attempt('c1'), // fails
          attempt('c2'), // fails — streak complete
          attempt('c3'), // blocked, breaker message
          attempt('c4'), // blocked, first retry
          attempt('c5'), // blocked, second retry — stop
        ]),
        plugins: [BreakerTool()]);
    var executions = 0;
    const failure = 'the task queue is empty';
    loop.registerExecutor('example', (input) async {
      executions++;
      return const ToolResult(failure, isError: true);
    });
    final outcome = await loop.runTurn(const Input('run', id: 't1'));
    expect(executions, 2);
    expect(outcome.stopReason, StopReason.error);
    expect(outcome.detail, contains('repeated a failing call'));
    expect(outcome.detail, contains('"example"'));
    expect(outcome.detail, contains('failed 2 times'));
    expect(outcome.detail, contains(failure));
    // Every attempt still paired: two failures, three refusals.
    expect(toolResults(loop), hasLength(5));
  });

  test('a success after a failure resets the counter', () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          attempt('c1'), // fails — streak of one
          attempt('c2'), // succeeds — streak cleared
          attempt('c3'), // fails — a streak of one again, not two
          attempt('c4'), // fails — executes; without the reset it would block
          scriptedReply('done'),
        ]),
        plugins: [BreakerTool()]);
    var executions = 0;
    final outcomes = [
      const ToolResult('nope', isError: true),
      const ToolResult('ok'),
      const ToolResult('nope', isError: true),
      const ToolResult('nope', isError: true),
    ];
    loop.registerExecutor('example', (input) async {
      executions++;
      return outcomes.removeAt(0);
    });
    final outcome = await loop.runTurn(const Input('run', id: 't1'));
    expect(outcome.stopReason, StopReason.complete);
    expect(executions, 4); // every call ran: the success cleared the streak
    final results = toolResults(loop);
    expect(results[1].content, 'ok');
    expect(results[3].content, 'nope'); // its own failure, not a refusal
    expect(results.where((r) => r.content.contains('not executed')), isEmpty);
  });

  test('a call that fails once then succeeds never meets the breaker',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          attempt('c1'), // fails
          attempt('c2'), // succeeds
          scriptedReply('done'),
        ]),
        plugins: [BreakerTool()]);
    var executions = 0;
    var failFirst = true;
    loop.registerExecutor('example', (input) async {
      executions++;
      final fail = failFirst;
      failFirst = false;
      return fail
          ? const ToolResult('nope', isError: true)
          : const ToolResult('ok');
    });
    final outcome = await loop.runTurn(const Input('run', id: 't1'));
    expect(outcome.stopReason, StopReason.complete);
    expect(executions, 2);
    final results = toolResults(loop);
    expect(results[0].content, 'nope');
    expect(results[1].content, 'ok');
  });

  test('argument keys are canonicalized, so key order cannot dodge the key',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          attempt('c1', input: {'a': 1, 'b': 2}),
          attempt('c2', input: {'b': 2, 'a': 1}), // same canonical form
          attempt('c3', input: {'a': 1, 'b': 2}), // blocked
          scriptedReply('done'),
        ]),
        plugins: [BreakerTool()]);
    var executions = 0;
    loop.registerExecutor('example', (input) async {
      executions++;
      return const ToolResult('nope', isError: true);
    });
    final outcome = await loop.runTurn(const Input('run', id: 't1'));
    expect(outcome.stopReason, StopReason.complete);
    expect(executions, 2);
    expect(toolResults(loop)[2].content, contains('not executed'));
  });
}
