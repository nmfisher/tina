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
      expect(b.turnSpendCompactTrigger(autoCompactThreshold: 560), isFalse);
    });

    test('true exactly at half the limit, still within budget', () {
      // ceil(1000 * 0.5) = 500: exactly at the rung fires, hard abort
      // (strict >) does not.
      var b = const TokenBudget(perTurnLimit: 1000)
          .record(const TokenUsage(inputTokens: 500, outputTokens: 0));
      expect(b.turnSpendCompactTrigger(autoCompactThreshold: 560), isTrue);
      expect(b.exceededLimit(), isNull,
          reason: 'the compact rung sits well below the hard cap');
    });

    test('false once the HARD cap is crossed — the hard reason wins', () {
      var b = const TokenBudget(perTurnLimit: 100)
          .record(const TokenUsage(inputTokens: 101, outputTokens: 0));
      expect(b.exceededLimit(), TokenLimitKind.perTurn);
      expect(b.turnSpendCompactTrigger(autoCompactThreshold: 560), isFalse,
          reason: 'past the cap the abort path owns the turn');
    });

    test('no per-turn limit: falls back to the absolute threshold baseline '
        '(tin-cmpt)', () {
      // The old code returned false whenever the cap was missing, which let
      // `--max-turn-tokens 0` remove the spend trigger and the hard abort at
      // once. Now the baseline is kNoCapTurnSpendCompactRatio (50%) of the
      // caller-supplied auto-compact threshold.
      final b = const TokenBudget()
          .record(const TokenUsage(inputTokens: 100000, outputTokens: 0));
      expect(b.turnSpendCompactTrigger(autoCompactThreshold: 560), isTrue,
          reason: '100000 ≥ ceil(560 × 0.5) = 280');
      expect(
          b.turnSpendCompactTrigger(autoCompactThreshold: 300000), isFalse,
          reason: '100000 < ceil(300000 × 0.5) = 150000');
      expect(b.turnSpendCompactTrigger(autoCompactThreshold: 0), isFalse,
          reason: 'threshold 0 disables compaction entirely, as before');
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

  group('Agent.run turn-spend compaction WITHOUT a per-turn cap (tin-cmpt)', () {
    // Sizing discipline. Three ladder marks, all from one threshold T:
    //   uncapped spend rung  = T/2   (measured+estimated spend)
    //   spend size floor     = T/2   (single-request estimate; BOTH the rung
    //                               and this floor must hold, so the request
    //                               must also be over T/2)
    //   size trigger         = T     (single-request estimate)
    // The #44 stubber keeps at most ~8 large results in history, so the
    // estimate SATURATES at base + 8 × R/4 instead of growing forever: with
    // R = 6000-byte results the request estimate parks near ~14400 — ABOVE
    // the T/2 floor of 10000, far BELOW the T size trigger of 20000. Per
    // round the turn records U = 1000 tokens, so spend reaches the 20000/2 =
    // 10000 rung after ~10 rounds while the estimate has been flat the whole
    // time. Every compaction this group sees comes from the UNCAPPED SPEND
    // rung; the size path can never fire (14400 < 20000).
    final medium = 'x' * 6000;

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

    Agent uncappedAgent(FakeProvider provider, {FakeAgentSink? sink}) {
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('big', (_) => ToolResult(medium)),
        ]),
        sink: sink ?? FakeAgentSink(),
        policy:
            PermissionPolicy(defaults: {'big': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.allowOnce,
        maxSteps: 30,
        system: 'sys',
      );
      agent
        ..autoCompactThreshold = 20000 // uncapped spend rung = 10000
        ..autoCompactKeepMessages = 2;
      // NO perTurnLimit — the exact posture `--max-turn-tokens 0` produces.
      agent.budget = const TokenBudget();
      return agent;
    }

    test(
        '(a) crossing the uncapped baseline compacts exactly once and the '
        'latch holds', () async {
      // Each tool round records 1000 tokens (input 500 + output 500):
      //   rounds 1..10 → 1000 … 10000 — the rung is reached at round 10
      //   round 11     → 11000 ≥ 10000 → the step-12 top fires ONE uncapped
      //                  spend compaction, sets the latch, and no later
      //                  round repeats it; the closing text then ends the
      //                  turn normally — no cap, no hard abort. The request
      //                  estimate is parked near ~14400 the whole time —
      //                  above the T/2 floor, below the T size trigger.
      final rounds = List.generate(11, (i) => toolUseWithUsage('t${i + 1}',
          const TokenUsage(inputTokens: 500, outputTokens: 500)));
      final provider = FakeProvider([
        ...rounds,
        summary(), // consumed by the uncapped spend compaction
        toolUseWithUsage(
            't12', const TokenUsage(inputTokens: 500, outputTokens: 500)),
        textWithUsage('done', const TokenUsage(inputTokens: 0, outputTokens: 0)),
      ]);
      final sink = FakeAgentSink();
      final agent = uncappedAgent(provider, sink: sink);

      await agent.run(history: <Message>[], userInput: 'go');

      // Exactly one compaction request left the wire, and it is the uncapped
      // spend one — under the old code this turn could never spend-compact.
      expect(provider.calls.where(isCompactCall), hasLength(1),
          reason: 'the uncapped spend rung fires the once-per-turn compaction');
      expect(agent.turnSpendCompactFired, isTrue);
      expect(
          sink.notices.any((n) =>
              n.message.contains('[compact]') &&
              n.message.contains('no per-turn cap')),
          isTrue,
          reason: 'the uncapped compaction announces its own reason');
      // The request after the summary carries the rebuilt history: the
      // summary TEXT from our scripted summary() call is embedded verbatim
      // in the 'Prior conversation summary:' wrapper.
      final compactCall = provider.calls.where(isCompactCall).single;
      final afterIdx = provider.calls.indexOf(compactCall);
      expect(
        provider.calls[afterIdx + 1].messages.any((m) => m.content.any((b) =>
            b is TextBlock && b.text.contains('progress summary'))),
        isTrue,
        reason: 'the model must see the summarized history afterwards',
      );
      // No cap means the turn ends NORMALLY — tin-cmpt criterion 2.
      expect(agent.abortedKind, AbortedKind.none);
      expect(agent.abortedReason, isNull);
    });

    test(
        '(b) the latch holds — spend far past the baseline never compacts '
        'again', () async {
      // 16 rounds × 1000 = 16000 measured tokens — 1.6× the uncapped rung of
      // 10000 — while the request estimate stays parked near ~14400, below
      // the 20000 size threshold. If the latch failed, the spend trigger
      // would re-fire and compact again; exactly one compaction call is in
      // the script.
      final rounds = List.generate(16, (i) => toolUseWithUsage('t${i + 1}',
          const TokenUsage(inputTokens: 500, outputTokens: 500)));
      final provider = FakeProvider([
        ...rounds,
        summary(), // the single compaction
        textWithUsage('done', const TokenUsage(inputTokens: 0, outputTokens: 0)),
      ]);
      final agent = uncappedAgent(provider);

      await agent.run(history: <Message>[], userInput: 'go');

      expect(provider.calls.where(isCompactCall), hasLength(1),
          reason: 'the once-per-turn latch bounds the uncapped trigger');
      expect(agent.turnSpendCompactFired, isTrue);
      expect(agent.abortedKind, AbortedKind.none,
          reason: 'no cap — no hard abort, even at triple the baseline');
    });

    test('(c) a short uncapped turn never compacts', () async {
      // Three rounds = 3000 tokens, well under the 10000 rung.
      final provider = FakeProvider([
        toolUseWithUsage(
            't1', const TokenUsage(inputTokens: 500, outputTokens: 500)),
        toolUseWithUsage(
            't2', const TokenUsage(inputTokens: 500, outputTokens: 500)),
        textWithUsage('done', const TokenUsage(inputTokens: 0, outputTokens: 0)),
      ]);
      final agent = uncappedAgent(provider);

      await agent.run(history: <Message>[], userInput: 'go');

      expect(provider.calls.where(isCompactCall), isEmpty);
      expect(agent.turnSpendCompactFired, isFalse);
      expect(agent.abortedReason, isNull);
    });
  });

  group('Agent.run no-checkpoint advisory (tin-cmpt)', () {
    // Small payloads, no auto-compact threshold tuning: the constructor
    // default (20000) never fires on 100-byte results. Spend is faked LARGE
    // (real TokenUsage numbers, not scaled constants) so the group crosses
    // the production [kNoCheckpointAdvisorySpend] of 300000 exactly as a
    // real long turn would — the ADVISORY is the only mechanism under test.
    final tiny = 'y' * 100;

    List<StreamEvent> toolUse(String id, String tool, TokenUsage usage) => [
          MessageComplete(
            content: [ToolUseBlock(id: id, name: tool, input: const {})],
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

    bool wireHasAdvisory(
            ({String system, List<Message> messages, List<ToolSchema> tools})
                call) =>
        call.messages.any((m) => m.content.any((b) =>
            b is TextBlock &&
            b.text.contains('[checkpoint] this turn has run long')));

    /// FakeProvider records the LIVE history list, so after the run every
    /// recorded call would alias the final (advisory-carrying) history. This
    /// variant snapshots the message list at send time so per-call wire
    /// assertions are honest.
    final snapshotProvider = _SnapshotProvider([
      ...List.generate(
          6,
          (i) => toolUse('t${i + 1}', 'peek',
              const TokenUsage(inputTokens: 50000, outputTokens: 50000))),
      textWithUsage('done', const TokenUsage(inputTokens: 0, outputTokens: 0)),
    ]);

    /// Six read-only tool rounds of 100000 tokens each (50000 in + 50000
    /// out), then a closing text. Spend walks 100000, 200000, 300000 ←
    /// crosses [kNoCheckpointAdvisorySpend] (300000) on round 3, so the
    /// step-4 request (call index 3) carries the advisory; rounds 4-6 prove
    /// the latch holds.
    Agent advisoryAgent(LlmProvider provider, FakeAgentSink sink,
        {String tool = 'peek'}) {
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool(tool, (_) => ToolResult(tiny)),
        ]),
        sink: sink,
        policy:
            PermissionPolicy(defaults: {tool: PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.allowOnce,
        maxSteps: 20,
        system: 'sys',
      );
      // NO perTurnLimit — `--max-turn-tokens 0`. The advisory is absolute, so
      // it exists exactly where the cap does not.
      agent.budget = const TokenBudget();
      return agent;
    }

    test('constants pin the seam', () {
      expect(kNoCheckpointAdvisorySpend, 300000);
      expect(kNoCheckpointAdvisoryLine, contains('[checkpoint]'));
      expect(kCheckpointTouchTools,
          unorderedEquals({'edit', 'write', 'bash'}));
    });

    test(
        'a long turn with no edit and no commit is told to land a checkpoint '
        '— once, in-band', () async {
      // Per-call wire assertions need send-time snapshots (see
      // [snapshotProvider]); the write-tool test below needs only end-state
      // assertions, so plain FakeProvider is fine there.
      final provider = snapshotProvider;
      final sink = FakeAgentSink();
      final agent = advisoryAgent(provider, sink);

      await agent.run(history: <Message>[], userInput: 'go');

      // The latch is set exactly once and the turn ends cleanly (no cap, so
      // no hard abort even far past the advisory spend).
      expect(agent.checkpointAdvisoryFired, isTrue);
      expect(agent.abortedKind, AbortedKind.none);
      expect(agent.abortedReason, isNull);
      // MODEL-VISIBLE: the advisory rode in-band on the request issued after
      // the crossing (step 4 = call index 3), and BEFORE that it never did.
      expect(wireHasAdvisory(provider.calls[3]), isTrue,
          reason: '300000 ≥ 300000 after round 3 — the next request must '
              'carry the advisory');
      expect(provider.calls.take(3).any(wireHasAdvisory), isFalse,
          reason: 'before the crossing the turn was under the spend line');
      // ONCE PER TURN: the advisory becomes part of history, so later
      // requests legitimately re-carry it — the latch property is that it
      // was INJECTED once. Count advisory messages in the final snapshot:
      // a broken latch would inject a fresh copy every step.
      final lastCall = provider.calls.last;
      final advisoryCount = lastCall.messages
          .where((m) => m.content.any((b) =>
              b is TextBlock &&
              b.text.contains('[checkpoint] this turn has run long')))
          .length;
      expect(advisoryCount, 1,
          reason: 'injected exactly once — the latch holds');
      // OPERATOR-VISIBLE: the stderr notice mirrors the model's message.
      expect(
          sink.notices.any((n) =>
              n.message.contains('[checkpoint]') &&
              n.kind == NoticeKind.warning),
          isTrue,
          reason: 'the operator must see the turn has no checkpoint');
    });

    test(
        'a turn that touches a mutable tool never gets the advisory — and '
        'the latch stays unset', () async {
      final rounds = List.generate(6, (i) => toolUse('t${i + 1}', 'write',
          const TokenUsage(inputTokens: 50000, outputTokens: 50000)));
      final provider = FakeProvider([
        ...rounds,
        textWithUsage('done', const TokenUsage(inputTokens: 0, outputTokens: 0)),
      ]);
      final sink = FakeAgentSink();
      final agent = advisoryAgent(provider, sink, tool: 'write');

      await agent.run(history: <Message>[], userInput: 'go');

      expect(agent.turnTouchedCheckpoint, isTrue,
          reason: 'every call was to write — a checkpoint exists');
      expect(agent.checkpointAdvisoryFired, isFalse,
          reason: 'a touched checkpoint suppresses the advisory');
      expect(provider.calls.any(wireHasAdvisory), isFalse,
          reason: 'nothing in-band: the model was never told to checkpoint');
      expect(sink.notices.any((n) => n.message.contains('[checkpoint]')),
          isFalse);
      expect(agent.abortedKind, AbortedKind.none);
    });
  });
}

/// A [LlmProvider] variant of FakeProvider that snapshots the message list at
/// send time. The plain fake records the LIVE history reference, which makes
/// per-call wire assertions useless once the run mutates history (an in-band
/// advisory stays visible in every recorded call). See tin-cmpt's advisory
/// tests.
class _SnapshotProvider extends LlmProvider {
  final List<List<StreamEvent>> responses;
  final List<({String system, List<Message> messages, List<ToolSchema> tools})>
      calls = [];
  int _index = 0;

  _SnapshotProvider(this.responses) : super('fake-model');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    calls.add((
      system: system,
      messages: List<Message>.of(messages),
      tools: tools,
    ));
    if (_index < responses.length) {
      for (final event in responses[_index++]) {
        yield event;
      }
    }
  }
}
