import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

/// Regression tests for tin-hist — the input editor's ↑/↓ recall history
/// must contain only messages the OPERATOR sent. The engine composes
/// user-role messages of its own (budget nudge, permission-mode
/// announcement, compaction summary) and marks them [Message.isSynthetic];
/// the TUI's startup replay filters on that flag.
void main() {
  group('Message.isSynthetic (tin-hist)', () {
    test('defaults to false — plain user messages need no change', () {
      const m = Message(role: Role.user, content: [TextBlock('typed by me')]);
      expect(m.isSynthetic, isFalse);
    });

    test('round-trips through the session journal', () {
      const m = Message(
          role: Role.user,
          isSynthetic: true,
          content: [TextBlock('Runtime permission mode: ask.')]);
      final back = Message.fromJson(m.toJson());
      expect(back.isSynthetic, isTrue);
      expect((back.content.single as TextBlock).text,
          'Runtime permission mode: ask.');
    });

    test('legacy journal lines without the key restore as non-synthetic', () {
      final back = Message.fromJson({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Prior conversation summary:\n\nold'}
        ],
      });
      expect(back.isSynthetic, isFalse,
          reason: 'a restored legacy summary must not erase typed prompts '
              'from the recall history');
    });

    test('assistant messages can carry the flag too', () {
      const m = Message(
          role: Role.assistant,
          isSynthetic: true,
          content: [TextBlock('Got it — continuing from this summary.')]);
      expect(m.isSynthetic, isTrue);
    });
  });

  group('Agent synthetic user-role messages (tin-hist)', () {
    test('the 90% soft-margin nudge is marked synthetic', () async {
      // Cap 30, two tool rounds of 14 → 28 spend = past the 90% margin (27);
      // the third round finishes the turn.
      final provider = FakeProvider([
        [
          MessageComplete(
            content: [ToolUseBlock(id: 't1', name: 'fake', input: const {})],
            stopReason: 'tool_use',
            usage: const TokenUsage(inputTokens: 14, outputTokens: 0),
          ),
        ],
        [
          MessageComplete(
            content: [ToolUseBlock(id: 't2', name: 'fake', input: const {})],
            stopReason: 'tool_use',
            usage: const TokenUsage(inputTokens: 14, outputTokens: 0),
          ),
        ],
        const [
          MessageComplete(
            content: [TextBlock('done')],
            stopReason: 'end_turn',
            usage: TokenUsage(inputTokens: 0, outputTokens: 0),
          ),
        ],
      ]);
      final history = <Message>[];
      await Agent(
        provider: provider,
        tools: ToolRegistry([FakeTool.noOp('fake')]),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(defaults: const {
          'fake': PermissionDecision.allow,
        }),
        asker: (_) async => PermissionResponse.allowOnce,
        budget: const TokenBudget(perTurnLimit: 30),
        autoCompactThreshold: 0,
        system: 'sys',
      ).run(history: history, userInput: 'run');

      final soft = history
          .where((m) =>
              m.role == Role.user &&
              m.content.any(
                  (b) => b is TextBlock && b.text.contains('turn spend at')))
          .toList();
      expect(soft, hasLength(1), reason: 'exactly one nudge, as before');
      expect(soft.single.isSynthetic, isTrue,
          reason: 'the nudge must be excluded from operator recall');
      // Still model-visible on the wire.
      expect(
          provider.calls.last.messages.any((m) =>
              m.isSynthetic &&
              m.content.any(
                  (b) => b is TextBlock && b.text.contains('turn spend at'))),
          isTrue);
    });

    test('the permission-mode announcement is marked synthetic', () async {
      // The announcement only fires on a MODE CHANGE (the initial ask state
      // is assumed known), so start in read-all and flip mid-run — the same
      // shape runtime_mode_gate_test uses.
      final policy = PermissionPolicy()..mode = PermissionMode.readAll;
      final provider = FakeProvider([
        const [
          MessageComplete(
            content: [TextBlock('first')],
            stopReason: 'end_turn',
            usage: TokenUsage(inputTokens: 0, outputTokens: 0),
          ),
        ],
        const [
          MessageComplete(
            content: [TextBlock('done')],
            stopReason: 'end_turn',
            usage: TokenUsage(inputTokens: 0, outputTokens: 0),
          ),
        ],
      ]);
      final history = <Message>[];
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        policy: policy,
        asker: (_) async => PermissionResponse.allowOnce,
        system: 'sys',
      );
      final first = agent.run(history: history, userInput: 'inspect');
      await first;
      policy.mode = PermissionMode.ask;
      await agent.run(history: history, userInput: 'again');

      // Every mode CHANGE announces (null→readAll in run 1, readAll→ask in
      // run 2) — both must be marked synthetic.
      final notices = history
          .where((m) =>
              m.role == Role.user &&
              m.content.any((b) =>
                  b is TextBlock &&
                  b.text.startsWith('Runtime permission mode:')))
          .toList();
      expect(notices, hasLength(2));
      expect(notices.every((m) => m.isSynthetic), isTrue);
    });

    test('an operator prompt stays non-synthetic', () async {
      final provider = FakeProvider([
        const [
          MessageComplete(
            content: [TextBlock('hello!')],
            stopReason: 'end_turn',
            usage: TokenUsage(inputTokens: 0, outputTokens: 0),
          ),
        ],
      ]);
      final history = <Message>[];
      await Agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.allowOnce,
        system: 'sys',
      ).run(history: history, userInput: 'hello there');

      final prompts = history.where((m) => m.role == Role.user).toList();
      expect(prompts.single.isSynthetic, isFalse);
    });

    test('compaction rebuild marks the summary pair synthetic', () async {
      // Compact directly: three old exchanges with preserveRecent: 2 splits
      // at the second-most-recent human turn, summarizing the oldest away.
      final provider = FakeProvider([
        [
          const TextDelta('SUMMARY'),
          const MessageComplete(
              content: [TextBlock('SUMMARY')], stopReason: 'end_turn'),
        ],
      ]);
      final history = <Message>[
        const Message(role: Role.user, content: [TextBlock('old q one')]),
        const Message(
            role: Role.assistant, content: [TextBlock('old a one enough')]),
        const Message(role: Role.user, content: [TextBlock('old q two')]),
        const Message(
            role: Role.assistant, content: [TextBlock('old a two enough')]),
        const Message(role: Role.user, content: [TextBlock('old q three')]),
        const Message(
            role: Role.assistant, content: [TextBlock('old a three enough')]),
      ];
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.allowOnce,
        system: 'sys',
      );
      final compacted = await agent.compact(history, preserveRecent: 2);
      expect(compacted, isTrue);
      final summary = history.first;
      expect(summary.role, Role.user);
      expect((summary.content.single as TextBlock).text,
          contains('Prior conversation summary'));
      expect(summary.isSynthetic, isTrue,
          reason: 'the summary is system-composed, not operator input');
      // The assistant ack rides along.
      final ack = history[1];
      expect(ack.role, Role.assistant);
      expect(ack.isSynthetic, isTrue);
      // ...and a typed prompt kept in the suffix stays non-synthetic.
      final keptUser = history.where((m) => m.role == Role.user).last;
      expect(keptUser.isSynthetic, isFalse);
    });

    test('journal shape: the flag serializes as an additive key only', () {
      const plain = Message(role: Role.user, content: [TextBlock('hi')]);
      expect(plain.toJson().containsKey('synthetic'), isFalse,
          reason: 'non-synthetic messages keep the journal shape unchanged');
      const marked = Message(
          role: Role.user,
          isSynthetic: true,
          content: [TextBlock('[budget] nudge')]);
      final json = marked.toJson();
      expect(json['synthetic'], isTrue);
      expect(json['role'], 'user');
      // Providers build wire payloads from role+content fields directly
      // (anthropic.dart/openai_compatible.dart/gemini.dart never read the
      // flag), so the flag cannot reach the model API.
    });
  });
}
