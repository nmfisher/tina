import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

void main() {
  test('exact suggestion escapes regex syntax and terminal controls', () {
    const command = 'echo "a.*(b)"\necho next';
    const prompt = PermissionPrompt('bash', {'command': command});
    final rule = prompt.regexRule(prompt.suggestedRegex);
    expect(rule.matches(prompt.target), isTrue);
    expect(prompt.suggestedRegex, isNot(contains('\n')));
    expect(
        rule.matches(PermissionPolicy.targetFor(
            'bash', {'command': 'echo "axyzb"\necho next'})),
        isFalse);
  });

  test('reviewed regex permits subsequent matches only', () async {
    final policy = PermissionPolicy();
    final executed = <String>[];
    var asks = 0;
    final provider = FakeProvider([
      [
        const MessageComplete(content: [
          ToolUseBlock(id: 'a', name: 'bash', input: {'command': 'git status'}),
          ToolUseBlock(id: 'b', name: 'bash', input: {'command': 'git diff'}),
          ToolUseBlock(id: 'c', name: 'bash', input: {'command': 'git push'}),
        ], stopReason: 'tool_use')
      ],
      [
        const MessageComplete(
            content: [TextBlock('done')], stopReason: 'end_turn')
      ],
    ]);
    final agent = Agent(
      provider: provider,
      tools: ToolRegistry([
        FakeTool('bash', (input) {
          executed.add(input['command'] as String);
          return const ToolResult('ok');
        }),
      ]),
      sink: FakeAgentSink(),
      policy: policy,
      system: '',
      asker: (prompt) async {
        asks++;
        if (asks > 1) return PermissionResponse.denyOnce;
        return PermissionResponse(PermissionDecision.allow,
            remember: true,
            scope: GrantScope.conversation,
            rule: prompt.regexRule('git (status|diff)'));
      },
    );
    await agent.run(history: [], userInput: 'check git');
    expect(asks, 2);
    expect(executed, ['git status', 'git diff']);
    expect(policy.sessionRules.single.isRegex, isTrue);
    expect(policy.sessionRules.single.pattern, 'git (status|diff)');
  });

  for (final cancel in [false, true]) {
    test(
        'invalid or cancelled review cannot dispatch or remember (cancel: $cancel)',
        () async {
      final stopped = Completer<void>();
      final policy = PermissionPolicy();
      var executed = false;
      final provider = FakeProvider([
        [
          const MessageComplete(content: [
            ToolUseBlock(
                id: 'a', name: 'bash', input: {'command': 'git status'})
          ], stopReason: 'tool_use')
        ],
        [
          const MessageComplete(
              content: [TextBlock('done')], stopReason: 'end_turn')
        ],
      ]);
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('bash', (_) {
            executed = true;
            return const ToolResult('ok');
          }),
        ]),
        sink: FakeAgentSink(),
        policy: policy,
        system: '',
        asker: (prompt) async {
          if (cancel) stopped.complete();
          return PermissionResponse(PermissionDecision.allow,
              remember: true,
              scope: GrantScope.conversation,
              rule: PermissionRule.regex(
                  toolName: 'bash',
                  pattern: cancel ? 'git status' : 'git push',
                  decision: PermissionDecision.allow));
        },
      );
      await agent.run(
          history: [], userInput: 'check git', cancelSignal: stopped.future);
      expect(executed, isFalse);
      expect(policy.sessionRules, isEmpty);
    });
  }
}
