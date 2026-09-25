import 'package:tina_app/src/goals/goal_judge.dart';
import 'package:tina_app/src/goals/goal_store.dart';
import 'package:tina_app/src/session/conversation.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// Verdict answers the fake judge turns return.
RunAgentResult _result(String text) => RunAgentResult(text);

Conversation _conversation({List<Message> history = const []}) {
  final provider = FakeProvider(const []);
  return Conversation(
    id: 'c1',
    label: 'test',
    agent: Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: FakeAgentSink(),
      policy: PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      system: 'sys',
    ),
    provider: provider,
    host: FakeHostInterface(),
    policy: PermissionPolicy(),
    initialHistory: history,
  );
}

void main() {
  group('GoalJudgeDigest', () {
    test('keeps user + assistant text, tool calls become markers', () {
      final digest = GoalJudgeDigest.build([
        const Message(role: Role.user, content: [TextBlock('fix the bug')]),
        Message(
          role: Role.assistant,
          content: [
            const TextBlock('On it — reading the file.'),
            ToolUseBlock(id: 't1', name: 'read', input: {'path': 'a.dart'}),
          ],
        ),
        const Message(role: Role.assistant, content: [TextBlock('Fixed.')]),
      ]);
      expect(digest, contains('user: fix the bug'));
      expect(digest, contains('assistant: On it — reading the file.'));
      expect(digest, contains('tool: read'));
      expect(digest, contains('assistant: Fixed.'));
    });

    test('caps the digest size on a huge transcript', () {
      final history = List<Message>.generate(
        200,
        (i) => Message(role: Role.assistant, content: [TextBlock('x' * 5000)]),
      );
      final digest = GoalJudgeDigest.build(history);
      expect(digest.length, lessThanOrEqualTo(GoalJudgeDigest.maxChars));
    });

    test('empty history renders the placeholder', () {
      expect(GoalJudgeDigest.build(const []), '(no transcript)');
    });
  });

  group('judgeGoal', () {
    test(
      'parses a yes verdict, records it, and announces the transition',
      () async {
        final store = GoalStore()..set('c1', 'fix the bug');
        final conversation = _conversation(
          history: [
            const Message(role: Role.user, content: [TextBlock('fix the bug')]),
            const Message(
              role: Role.assistant,
              content: [TextBlock('Done — tests pass.')],
            ),
          ],
        );
        final seen = <String>[];
        final verdict = await judgeGoal(
          store: store,
          conversation: conversation,
          runCheck: ({required systemPrompt, required task, required sink}) {
            seen.add(task);
            return Future.value(
              _result(
                'VERDICT: yes — the transcript shows the failing test now '
                'passes.',
              ),
            );
          },
        );
        expect(verdict, GoalVerdict.achieved);
        expect(store.read('c1').status!.verdict, GoalVerdict.achieved);
        expect(store.read('c1').status!.evidence, contains('test'));
        // The judge task carried the goal and the transcript digest.
        expect(seen.single, contains('GOAL: fix the bug'));
        expect(seen.single, contains('RECENT TRANSCRIPT:'));
        // The host heard the achieved notice.
        expect(
          (conversation.host as FakeHostInterface).notices,
          anyElement(contains('goal achieved')),
        );
        store.dispose();
      },
    );

    test('a repeat verdict stays silent; a transition re-announces', () async {
      final store = GoalStore()..set('c1', 'fix the bug');
      final conversation = _conversation();
      Future<GoalVerdict?> judge(String answer) => judgeGoal(
        store: store,
        conversation: conversation,
        runCheck: ({required systemPrompt, required task, required sink}) =>
            Future.value(_result(answer)),
      );
      await judge('VERDICT: yes — done.');
      final noticesAfterFirst =
          (conversation.host as FakeHostInterface).notices.length;
      await judge('VERDICT: yes — still done.');
      expect(
        (conversation.host as FakeHostInterface).notices.length,
        noticesAfterFirst,
      );
      await judge('VERDICT: unclear — the digest is thin.');
      expect(
        (conversation.host as FakeHostInterface).notices.length,
        greaterThan(noticesAfterFirst),
      );
      store.dispose();
    });

    test('no/unclear verdicts record without an achieved notice', () async {
      final store = GoalStore()..set('c1', 'fix the bug');
      final conversation = _conversation();
      final verdict = await judgeGoal(
        store: store,
        conversation: conversation,
        runCheck: ({required systemPrompt, required task, required sink}) =>
            Future.value(_result('VERDICT: no — work continues.')),
      );
      expect(verdict, GoalVerdict.inProgress);
      expect(store.read('c1').status!.verdict, GoalVerdict.inProgress);
      expect((conversation.host as FakeHostInterface).notices, isEmpty);
      store.dispose();
    });

    test('an aborted last turn skips the check unless forced', () async {
      final store = GoalStore()..set('c1', 'fix the bug');
      final conversation = _conversation();
      conversation.agent.abortedReason = 'rate limited';
      var calls = 0;
      Future<RunAgentResult> check({
        required String systemPrompt,
        required String task,
        required AgentSink sink,
      }) async {
        calls++;
        return _result('VERDICT: no — nothing.');
      }

      expect(
        await judgeGoal(
          store: store,
          conversation: conversation,
          runCheck: check,
        ),
        isNull,
      );
      expect(calls, 0);
      expect(
        await judgeGoal(
          store: store,
          conversation: conversation,
          runCheck: check,
          force: true,
        ),
        GoalVerdict.inProgress,
      );
      expect(calls, 1);
      store.dispose();
    });

    test(
      'a judge call failure returns null and leaves the goal untouched',
      () async {
        final store = GoalStore()..set('c1', 'fix the bug');
        final conversation = _conversation();
        final verdict = await judgeGoal(
          store: store,
          conversation: conversation,
          runCheck: ({required systemPrompt, required task, required sink}) =>
              Future.value(RunAgentResult('provider exploded', isError: true)),
        );
        expect(verdict, isNull);
        expect(store.read('c1').hasVerdict, isFalse);
        store.dispose();
      },
    );

    test('an unparseable answer returns null (fail closed)', () async {
      final store = GoalStore()..set('c1', 'fix the bug');
      final conversation = _conversation();
      final verdict = await judgeGoal(
        store: store,
        conversation: conversation,
        runCheck: ({required systemPrompt, required task, required sink}) =>
            Future.value(_result('I think it went pretty well overall!')),
      );
      expect(verdict, isNull);
      expect(store.read('c1').hasVerdict, isFalse);
      store.dispose();
    });

    test('no goal or no conversation short-circuits to null', () async {
      final store = GoalStore();
      var called = false;
      Future<RunAgentResult> check({
        required String systemPrompt,
        required String task,
        required AgentSink sink,
      }) async {
        called = true;
        return _result('VERDICT: yes — x');
      }

      expect(
        await judgeGoal(
          store: store,
          conversation: _conversation(),
          runCheck: check,
        ),
        isNull,
      );
      expect(called, isFalse);
      expect(
        await judgeGoal(
          store: store..set('c1', 'goal'),
          conversation: null,
          runCheck: check,
        ),
        isNull,
      );
      expect(called, isFalse);
      store.dispose();
    });
  });
}
