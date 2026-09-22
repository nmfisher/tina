import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

void main() {
  for (final withInvocation in [false, true]) {
    test(
        'cancel approval stops the batch and waits for input (invocation: $withInvocation)',
        () async {
      final provider = FakeProvider([
        [
          const MessageComplete(content: [
            ToolUseBlock(id: 'one', name: 'bash', input: {'command': 'first'}),
            ToolUseBlock(id: 'two', name: 'bash', input: {'command': 'second'}),
          ], stopReason: 'tool_use')
        ],
        [
          const MessageComplete(
              content: [TextBlock('next instruction received')],
              stopReason: 'end_turn')
        ],
      ]);
      var executions = 0;
      var approvals = 0;
      final policy = PermissionPolicy();
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('bash', (_) {
            executions++;
            return const ToolResult('ran');
          })
        ]),
        sink: FakeAgentSink(),
        policy: policy,
        system: '',
        asker: (_) async {
          approvals++;
          return PermissionResponse.cancel;
        },
      );
      final history = <Message>[];
      if (withInvocation) {
        final call = Invocations().create(
          component: const ComponentInfo('test.agent', 'Agent'),
          conversationId: 'test',
        );
        await expectLater(
          call.run((_) => agent.run(history: history, userInput: 'start')),
          throwsA(isA<InvocationCancelled>()),
        );
        expect(call.isCancelled, isTrue);
      } else {
        await agent.run(history: history, userInput: 'start');
      }
      expect(provider.calls, hasLength(1));
      expect(approvals, 1);
      expect(executions, 0);
      expect(policy.sessionRules, isEmpty);
      expect(agent.abortedKind, AbortedKind.cancel);
      final results = history
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .toList();
      expect(results.map((r) => r.toolUseId), ['one', 'two']);
      expect(results.every((r) => r.isError), isTrue);

      await agent.run(history: history, userInput: 'do this instead');
      expect(provider.calls, hasLength(2));
      expect(
          provider.calls.last.messages
              .where((m) => m.role == Role.user)
              .last
              .content
              .whereType<TextBlock>()
              .single
              .text,
          'do this instead');
    });
  }
}
