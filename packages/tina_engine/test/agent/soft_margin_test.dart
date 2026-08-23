import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

/// Regression tests for #37 — the per-turn budget SOFT margin. When the
/// recorded spend for the current turn first reaches ~90% of the per-turn
/// limit, the agent injects ONE user-role message into the turn's history
/// telling the model to land cleanly. The hard abort at 100% is untouched.
///
/// Model-visible delivery (#27 lesson): the message must enter the
/// conversation the model sees — `sink.notice` alone reaches only the
/// UI/stderr. These tests therefore assert against the turn's `history`
/// and against the provider's outgoing `calls` (what actually left the
/// wire), not against sink notices (which are asserted as the UI mirror).
void main() {
  group('TokenBudget.softMarginNotice (#37)', () {
    test('named constant is the 90% soft margin', () {
      expect(kPerTurnSoftMarginRatio, 0.9);
    });

    test('null before spend reaches 90% of the per-turn limit', () {
      // 90% of 1000 = 900; spend of 899 is still under.
      var b = const TokenBudget(perTurnLimit: 1000)
          .record(const TokenUsage(inputTokens: 899, outputTokens: 0));
      expect(b.softMarginNotice(), isNull);
    });

    test('non-null exactly at 90%, still within budget (no hard trip)', () {
      // 900/1000 = exactly the margin: the soft notice fires, the hard
      // abort (strict >) does not.
      var b = const TokenBudget(perTurnLimit: 1000)
          .record(const TokenUsage(inputTokens: 900, outputTokens: 0));
      expect(b.exceeded(), isNull, reason: 'hard abort stays above 100%');
      final notice = b.softMarginNotice();
      expect(notice, isNotNull);
      expect(notice, contains('90%'));
      expect(notice, contains('closing summary'));
    });

    test('null once the hard cap is crossed — the hard reason wins', () {
      var b = const TokenBudget(perTurnLimit: 100)
          .record(const TokenUsage(inputTokens: 101, outputTokens: 0));
      expect(b.exceeded(), isNotNull, reason: 'hard trip at 101 > 100');
      expect(b.softMarginNotice(), isNull,
          reason: 'past the hard cap the soft notice must not fire');
    });

    test('null without a per-turn limit', () {
      final b = const TokenBudget()
          .record(const TokenUsage(inputTokens: 100000, outputTokens: 0));
      expect(b.softMarginNotice(), isNull);
    });
  });

  group('Agent soft margin (#37)', () {
    /// User-role history messages carrying the soft-margin text — the
    /// model-visible nudge. Tool results never match: they carry
    /// ToolResultBlocks, not TextBlocks.
    List<Message> _softMessages(List<Message> history) => history
        .where((m) =>
            m.role == Role.user &&
            m.content.any((b) =>
                b is TextBlock && b.text.contains('turn spend at')))
        .toList();

    /// Wire payload of [callIndex]-th provider call carrying the soft text —
    /// proof the message actually reached the model, not just the history.
    bool _wireContains(FakeProvider provider, int callIndex, String needle) =>
        provider.calls[callIndex].messages
            .any((m) =>
                m.content.any((b) => b is TextBlock && b.text.contains(needle)));

    Agent _softAgent(FakeProvider provider) => Agent(
          provider: provider,
          tools: ToolRegistry([FakeTool.noOp('fake')]),
          sink: FakeAgentSink(),
          policy:
              PermissionPolicy(defaults: const {'fake': PermissionDecision.allow}),
          asker: (_) async => PermissionResponse.allowOnce,
          budget: const TokenBudget(perTurnLimit: 30),
          system: 'sys',
        );

    List<StreamEvent> _toolRound(String id, int tokens) => [
          MessageComplete(
            content: [ToolUseBlock(id: id, name: 'fake', input: const {})],
            stopReason: 'tool_use',
            usage: TokenUsage(inputTokens: tokens, outputTokens: 0),
          ),
        ];

    List<StreamEvent> _finish() => [
          const MessageComplete(
            content: [TextBlock('done')],
            stopReason: 'end_turn',
            usage: TokenUsage(inputTokens: 0, outputTokens: 0),
          ),
        ];

    test(
        '(a) spend reaching 90% injects the nudge exactly once, '
        'model-visible, and the turn still completes', () async {
      // Cap 30, rounds of 14: after round 2 spend is 28 = 93.3% — past the
      // 90% margin (27) but under the hard cap (30), so the turn finishes.
      final provider = FakeProvider([
        _toolRound('t1', 14),
        _toolRound('t2', 14),
        _finish(),
      ]);
      final agent = _softAgent(provider);
      final history = <Message>[];

      await agent.run(history: history, userInput: 'run');

      final soft = _softMessages(history);
      expect(soft, hasLength(1),
          reason: 'exactly one soft-margin message in the turn history');
      expect((soft.single.content.single as TextBlock).text, contains('90%'));
      expect((soft.single.content.single as TextBlock).text,
          contains('closing summary'));
      // It landed BEFORE the model's next request — that request is call
      // index 2 (after the two tool rounds).
      expect(_wireContains(provider, 2, 'turn spend at'), isTrue,
          reason: 'the nudge must be model-visible on the wire');
      // No re-fire: the later spend (28, then the finish) stays past 90%
      // yet only ONE message exists in the whole history.
      expect(agent.softMarginFired, isTrue);
      // The turn completed cleanly — the nudge must not itself abort.
      expect(agent.abortedReason, isNull);
      expect(agent.abortedKind, AbortedKind.none);
      // UI mirror: the transcript shows the same text (convenience, not
      // delivery).
      expect(agent.sink, isA<FakeAgentSink>());
      expect(
          (agent.sink as FakeAgentSink)
              .notices
              .any((n) => n.message.contains('turn spend at')),
          isTrue,
          reason: 'the UI transcript mirrors the injected nudge');
    });

    test('(b) the nudge appears BEFORE the hard abort when the limit trips',
        () async {
      // Cap 30, rounds of 15: round 1 → 15 (< 27, nothing); round 2 → 30
      // (>= 27, soft fires; 30 is NOT > 30, so no hard abort yet); round 3
      // → 45 > 30 → hard abort. The soft message must sit in history before
      // the turn dies, and on the transcript before the abort notice.
      final provider = FakeProvider([
        _toolRound('t1', 15),
        _toolRound('t2', 15),
        _toolRound('t3', 15),
      ]);
      final agent = _softAgent(provider);
      final history = <Message>[];

      await agent.run(history: history, userInput: 'run');

      final soft = _softMessages(history);
      expect(soft, hasLength(1),
          reason: 'the soft nudge fires once on the way down');
      expect(agent.abortedKind, AbortedKind.budget,
          reason: 'the hard abort still trips at 100%');
      expect(agent.abortedReason, contains('per-turn'));
      // Ordering: the nudge precedes the final (aborted) assistant message.
      final softIndex = history.indexOf(soft.single);
      final lastAssistantIndex = history.lastIndexWhere(
          (m) => m.role == Role.assistant && m.content.any((b) => b is ToolUseBlock));
      expect(softIndex, greaterThanOrEqualTo(0));
      expect(softIndex, lessThan(lastAssistantIndex),
          reason: 'model saw the nudge before the turn was aborted');
      // Transcript ordering: the warning nudge precedes the error abort.
      final notices = (agent.sink as FakeAgentSink).notices;
      final softNotice = notices.indexWhere(
          (n) => n.message.contains('turn spend at'));
      final abortNotice = notices.indexWhere(
          (n) => n.message.contains('per-turn token budget exceeded'));
      expect(softNotice, greaterThanOrEqualTo(0));
      expect(softNotice, lessThan(abortNotice));
    });

    test('(c) a turn that stays under 90% produces no message', () async {
      // Cap 30, spend of 5 then finish: 5/30 = 16.7%, nowhere near 90%.
      final provider = FakeProvider([
        _toolRound('t1', 5),
        _finish(),
      ]);
      final agent = _softAgent(provider);
      final history = <Message>[];

      await agent.run(history: history, userInput: 'run');

      expect(_softMessages(history), isEmpty,
          reason: 'under 90% there is no nudge at all');
      expect(agent.softMarginFired, isFalse);
      expect(agent.abortedReason, isNull,
          reason: 'no behavior change below the margin');
      expect(
          (agent.sink as FakeAgentSink)
              .notices
              .any((n) => n.message.contains('turn spend at')),
          isFalse);
    });
  });
}