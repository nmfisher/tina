import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

TurnContext request(
        {String system = 'system',
        String text = 'task',
        List<ToolSchema> tools = const []}) =>
    TurnContext(CancelToken(),
        input: const Input('task', id: 'test'),
        messages: [
          Message(role: Role.user, content: [TextBlock(text)])
        ],
        promptSections: [system],
        pinnedTools: tools);

final class _EditAfterTools extends AgentPlugin {
  _EditAfterTools(this.context);
  final ContextPlugin context;
  var calls = 0;
  @override
  String get id => 'test/edit';
  @override
  int get order => 700;
  @override
  void beforeModelCall(TurnContext c) {
    if (++calls != 2) return;
    final current = context.workingContext;
    context.replaceWorkingContext(
        expectedRevision: current.revision,
        expectedThroughSeq: current.throughSeq,
        messages: [
          current.messages.firstWhere((m) =>
              m.role == Role.user &&
              m.content.whereType<TextBlock>().any((b) => b.text == 'task'))
        ]);
  }
}

void main() {
  test('counts system, Unicode messages, tool definitions and its own gauge',
      () {
    final policy = ContextBudget();
    final context = request(text: '你好' * 100, tools: [
      ToolSchema(
          name: 'inspect',
          description: 'documentation' * 100,
          inputSchema: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'}
            }
          })
    ]);
    final before = estimateContextTokens(serializeContextRequest(context));
    policy.prepare(context, budget: 32000, reserve: 2048);
    final json = serializeContextRequest(context);
    expect(jsonDecode(json)['tools'][0]['input_schema']['properties'],
        contains('path'));
    expect(
        policy.latestUsage!.inputTokens, (utf8.encode(json).length / 4).ceil());
    expect(policy.latestUsage!.inputTokens, greaterThan(before));
    expect(
        context.promptSections.join('\n'), contains('input tokens remaining'));
    expect(policy.latestUsage!.remainingInputTokens,
        32000 - 2048 - policy.latestUsage!.inputTokens);
  });

  test('25/50/75 reminders fire on crossings and rearm after reductions', () {
    var tokens = 249;
    final policy = ContextBudget(counter: (_) => tokens);
    String? prepare() {
      policy.prepare(request(), budget: 1000, reserve: 100);
      return policy.latestUsage!.reminder;
    }

    expect(prepare(), isNull);
    for (final threshold in [250, 500, 750]) {
      tokens = threshold;
      expect(prepare(), contains('${threshold ~/ 10}%'));
      expect(prepare(), isNull);
    }
    tokens = 200;
    expect(prepare(), isNull);
    tokens = 250;
    expect(prepare(), contains('25%'));
    policy.reset();
    expect(policy.latestUsage, isNull);
    expect(prepare(), contains('25%'));
  });

  test('urgent reminders repeat and preserve signed overflow amount', () {
    var tokens = 900;
    final policy = ContextBudget(counter: (_) => tokens);
    for (var i = 0; i < 2; i++) {
      policy.prepare(request(), budget: 1000, reserve: 100);
      expect(policy.latestUsage!.reminder, contains('URGENT'));
      expect(policy.latestUsage!.remainingInputTokens, 0);
    }
    tokens = 1200;
    policy.prepare(request(), budget: 1000, reserve: 100);
    expect(policy.latestUsage!.remainingInputTokens, -300);
    expect(policy.latestUsage!.reminder, contains('URGENT'));
    policy.prepare(request(), budget: 4000, reserve: 100);
    expect(policy.latestUsage!.reminder, contains('25%'));
  });

  test('invalid reserve and token counters cannot prepare a request', () {
    final policy = ContextBudget();
    for (final reserve in [-1, 1000, 1001]) {
      expect(() => policy.prepare(request(), budget: 1000, reserve: reserve),
          throwsFormatException);
    }
    expect(
        () => ContextBudget(counter: (_) => -1)
            .prepare(request(), budget: 1000, reserve: 100),
        throwsStateError);
  });

  test('live edit reduces request usage while reminders stay out of the log',
      () async {
    final context =
        ContextPlugin(budgetTokens: 2000, responseReserveTokens: 200);
    final provider = ScriptedProvider([
      scriptedReply('',
          calls: const [ToolUseBlock(id: 'call', name: 'noop', input: {})]),
      scriptedReply('done'),
    ]);
    final history =
        Message(role: Role.user, content: [TextBlock('history' * 2000)]);
    final loop = AgentLoop(provider: provider, plugins: [
      _EditAfterTools(context),
      context
    ], seedLog: [
      const TurnStartedEntry(turnId: 'old', seq: 0),
      MessageAppendedEntry(turnId: 'old', seq: 1, message: history),
      const TurnEndedEntry(
          turnId: 'old', seq: 2, reason: TurnStopReason.complete),
    ]);
    loop.mountPlugin(context);
    loop.registerExecutor('noop', (_) async => const ToolResult('settled'));
    await loop.runTurn(const Input('task', id: 'new'));
    expect(provider.requests.first.systemPrompt, contains('URGENT'));
    expect(provider.requests.last.systemPrompt, isNot(contains('URGENT')));
    expect(context.latestEditTokensSaved, greaterThan(3000));
    expect(context.budgetUsage!.remainingInputTokens, greaterThan(0));
    expect(loop.log.whereType<MessageAppendedEntry>().first.message,
        same(history));
    expect(
        loop.log
            .whereType<MessageAppendedEntry>()
            .expand((e) => e.message.content)
            .whereType<TextBlock>()
            .any((b) => b.text.contains('Context budget')),
        isFalse);
    context.closeSession();
    expect(context.budgetUsage, isNull);
  });
}
