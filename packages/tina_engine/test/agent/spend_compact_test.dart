import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

/// Regression tests for #43 — the CUMULATIVE turn-spend compaction trigger.
/// The request-size auto-compact fires only when a single request's estimate
/// crosses the threshold; #42 measured the failure mode that actually occurs
/// (a 45-step turn re-sending ~40K of context per step ≈ 1.8M tokens while no
/// single request ever grew "large"), which needs a trigger on `turnTotal`
/// instead. When spend FIRST crosses [kTurnSpendCompactRatio] (50%) of the
/// per-turn limit, the SAME in-place compaction runs — once per turn (latch),
/// same machinery and assistant-boundary splitting as the size path.
///
/// The full spend ladder after this item: 50% compact → 90% soft nudge (#37)
/// → 100% hard abort (untouched).
void main() {
  group('TokenBudget.turnSpendCompactTrigger (#43)', () {
    test('named constant is the 50% compact rung', () {
      expect(kTurnSpendCompactRatio, 0.5);
    });

    test('false below half the per-turn limit', () {
      var b = const TokenBudget(perTurnLimit: 1000)
          .record(const TokenUsage(inputTokens: 499, outputTokens: 0));
      expect(b.turnSpendCompactTrigger(), isFalse);
    });

    test('true exactly at half the limit, still within budget', () {
      // ceil(1000 * 0.5) = 500: exactly at the rung fires, hard abort
      // (strict >) does not.
      var b = const TokenBudget(perTurnLimit: 1000)
          .record(const TokenUsage(inputTokens: 500, outputTokens: 0));
      expect(b.turnSpendCompactTrigger(), isTrue);
      expect(b.exceededLimit(), isNull,
          reason: 'the compact rung sits well below the hard cap');
    });

    test('false once the HARD cap is crossed — the hard reason wins', () {
      var b = const TokenBudget(perTurnLimit: 100)
          .record(const TokenUsage(inputTokens: 101, outputTokens: 0));
      expect(b.exceededLimit(), TokenLimitKind.perTurn);
      expect(b.turnSpendCompactTrigger(), isFalse,
          reason: 'past the cap the abort path owns the turn');
    });

    test('false without a per-turn limit', () {
      final b = const TokenBudget()
          .record(const TokenUsage(inputTokens: 100000, outputTokens: 0));
      expect(b.turnSpendCompactTrigger(), isFalse);
    });
  });

  group('Agent.run turn-spend compaction (#43)', () {
    // Payload sized against a 560-token threshold with a 280-token floor.
    // Request estimates across the turn (measured against
    // [TokenBudget.estimateInputTokens] = serialized bytes ~/ 4, schemas
    // included): results ACCUMULATE, so the turn's largest pre-compact
    // request — three 600-byte results in context — estimates ~465 tokens,
    // not the ~150 a single payload suggests. The band must hold: floor
    // (280) < every estimate at a spend-rung checkpoint, and every request
    // estimate < 560 so ONLY the spend trigger can ever fire a compaction.
    final medium = 'x' * 600;

    List<StreamEvent> toolUseWithUsage(String id, TokenUsage usage) => [
          MessageComplete(
            content: [ToolUseBlock(id: id, name: 'big', input: const {})],
            stopReason: 'tool_use',
            usage: usage,
          ),
        ];

    List<StreamEvent> textWithUsage(String t, TokenUsage usage) => [
          MessageComplete(
            content: [TextBlock(t)],
            stopReason: 'end_turn',
            usage: usage,
          ),
        ];

    List<StreamEvent> summary() => [
          const TextDelta('progress summary'),
          const MessageComplete(
              content: [TextBlock('progress summary')], stopReason: 'end_turn'),
        ];

    bool isCompactCall(
            ({String system, List<Message> messages, List<ToolSchema> tools})
                call) =>
        call.messages.any((m) => m.content.any((b) =>
            b is TextBlock &&
            b.text.contains('Summarize the conversation above')));

    bool wireHasSoftNudge(List<Message> messages) => messages.any((m) =>
        m.role == Role.user &&
        m.content.any((b) =>
            b is TextBlock && b.text.contains('turn spend at')));

    Agent spendAgent(FakeProvider provider, {FakeAgentSink? sink}) {
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('big', (_) => ToolResult(medium)),
        ]),
        sink: sink ?? FakeAgentSink(),
        policy:
            PermissionPolicy(defaults: {'big': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.allowOnce,
        maxSteps: 20,
        system: 'sys',
      );
      agent
        ..autoCompactThreshold = 560 // floor = 280; estimates above clear it
        ..autoCompactKeepMessages = 2;
      agent.budget = const TokenBudget(perTurnLimit: 200);
      return agent;
    }

    test(
        '(a) crossing 50% of the per-turn limit compacts in place EXACTLY '
        'once, then the 90% soft margin still fires later in the same turn',
        () async {
      // Ladder arithmetic against perTurnLimit=200. Each tool round records
      // 45 tokens (input 25 + output 20):
      //   round 1 → 45   (22%: nothing)
      //   round 2 → 90   (45%: nothing)
      //   round 3 → 135  (67%: crosses the 50% rung, but the triggers are
      //                   checked at STEP TOPS — round 3's own request still
      //                   went out over the full history)
      //   step-4 top → spend 135 ≥ 100 rung, estimate ~465 clears the floor
      //   and sits under the 560 size threshold → ONE spend compaction,
      //   latched (call idx 3 in the script below); round 4's request goes
      //   out over the summarized history
      //   round 4 → 180  (= 90% rung → the soft nudge fires once, appended
      //   for round 5's request)
      //   round 5 → 225  (> 200: hard abort — unchanged behavior; round 5's
      //   post-compact request estimates ~382, still under 560, so the size
      //   trigger never fires anywhere in the turn)
      final provider = FakeProvider([
        toolUseWithUsage(
            't1', const TokenUsage(inputTokens: 25, outputTokens: 20)),
        toolUseWithUsage(
            't2', const TokenUsage(inputTokens: 25, outputTokens: 20)),
        toolUseWithUsage(
            't3', const TokenUsage(inputTokens: 25, outputTokens: 20)),
        summary(), // consumed by the spend-triggered compaction (call idx 3)
        toolUseWithUsage(
            't4', const TokenUsage(inputTokens: 25, outputTokens: 20)),
        toolUseWithUsage(
            't5', const TokenUsage(inputTokens: 25, outputTokens: 20)),
      ]);
      final agent = spendAgent(provider);

      await agent.run(history: <Message>[], userInput: 'go');

      // Exactly one compaction request left the wire — the spend one.
      expect(provider.calls.where(isCompactCall), hasLength(1),
          reason: 'the once-per-turn latch must bound the spend trigger');
      expect(agent.turnSpendCompactFired, isTrue);
      // It fired at the 50% rung (turnTotal 120/200), not the size trigger:
      // the estimate (~150-160 tokens) stayed under the 200 size threshold.
      // The compaction notice names the spend reason.
      final notices = (agent.sink as FakeAgentSink).notices;
      expect(
        notices.any((n) => n.message.contains('[compact]') &&
            n.message.contains('crossed 50%')),
        isTrue,
        reason: 'the spend-triggered compaction announces itself',
      );
      // The post-compaction turn request (call index 4, right after the
      // summary) carries the rebuilt summary exchange — the history was
      // rewritten IN PLACE.
      expect(
        provider.calls[4].messages.any((m) => m.content.any((b) =>
            b is TextBlock &&
            b.text.contains('Prior conversation summary'))),
        isTrue,
        reason: 'the model must see the summarized history afterwards',
      );
      // …and the ladder continued: the 90% soft nudge still fired later in
      // the SAME turn (after round 6 pushed spend to 200 = 100%·0.9 rung).
      expect(agent.softMarginFired, isTrue,
          reason: '50% compaction does not suppress the 90% nudge');
      // Wire-level: exactly one outgoing request carried the nudge.
      final nudgedCalls =
          provider.calls.where((c) => wireHasSoftNudge(c.messages)).length;
      expect(nudgedCalls, greaterThanOrEqualTo(1),
          reason: 'the nudge must be model-visible on the wire');
      // The turn ended in the hard budget abort, exactly as before #43.
      expect(agent.abortedKind, AbortedKind.budget);
      expect(agent.abortedReason, contains('per-turn'));
    });

    test('(b) a turn that stays under 50% never compacts', () async {
      // Two rounds of 45 = 90 total against a limit of 200 → 45%, under the
      // rung; the closing text response records nothing, and the turn ends
      // before any later step-top could re-check the trigger. Round 3's
      // request carries both 600-byte results (~314 estimated tokens) — over
      // the floor but well under the 560 size threshold — so NOTHING may
      // compact.
      final provider = FakeProvider([
        toolUseWithUsage(
            't1', const TokenUsage(inputTokens: 25, outputTokens: 20)),
        toolUseWithUsage(
            't2', const TokenUsage(inputTokens: 25, outputTokens: 20)),
        textWithUsage('done', const TokenUsage(inputTokens: 0, outputTokens: 0)),
      ]);
      final agent = spendAgent(provider);

      await agent.run(history: <Message>[], userInput: 'go');

      expect(provider.calls.where(isCompactCall), isEmpty,
          reason: 'under the 50% rung there is no spend compaction');
      expect(agent.turnSpendCompactFired, isFalse);
      expect(agent.abortedReason, isNull,
          reason: '80 spent of 200 — the turn just finishes normally');
    });
  });
}
