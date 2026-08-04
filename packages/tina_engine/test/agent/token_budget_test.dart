import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

void main() {
  group('TokenBudget', () {
    test('null limits never trip', () {
      var b = TokenBudget();
      b = b.record(
          const TokenUsage(inputTokens: 1000000, outputTokens: 1000000));
      expect(b.exceeded(), isNull);
    });

    test('per-turn limit trips when cumulative exceeds', () {
      var b = TokenBudget(perTurnLimit: 1000);
      b = b.record(const TokenUsage(inputTokens: 400, outputTokens: 100));
      expect(b.exceeded(), isNull);
      b = b.record(const TokenUsage(inputTokens: 400, outputTokens: 200));
      expect(b.exceeded(), contains('per-turn'));
    });

    test('exceededLimit reports which cap tripped (or null)', () {
      var turn = TokenBudget(perTurnLimit: 1000);
      turn = turn.record(const TokenUsage(inputTokens: 400, outputTokens: 700));
      expect(turn.exceededLimit(), TokenLimitKind.perTurn);

      var session = TokenBudget(perSessionLimit: 1000);
      session =
          session.record(const TokenUsage(inputTokens: 400, outputTokens: 700));
      expect(session.exceededLimit(), TokenLimitKind.perSession);

      // Per-turn is checked first, so when both are crossed it wins.
      var both = TokenBudget(perTurnLimit: 500, perSessionLimit: 1000);
      both = both.record(const TokenUsage(inputTokens: 400, outputTokens: 700));
      expect(both.exceededLimit(), TokenLimitKind.perTurn);

      expect(TokenBudget().exceededLimit(), isNull);
    });

    test('resetTurn clears turn total but keeps session total', () {
      var b = TokenBudget(perTurnLimit: 1000, perSessionLimit: 10000);
      b = b.record(const TokenUsage(inputTokens: 800, outputTokens: 100));
      b = b.resetTurn();
      expect(b.turnTotal, 0);
      expect(b.sessionTotal, 900);
      // A second 800/100 turn would re-trip turn cap without reset; with
      // reset it stays clean since 900 < 1000.
      b = b.record(const TokenUsage(inputTokens: 80, outputTokens: 10));
      expect(b.exceeded(), isNull);
    });

    test('resetSession clears both counters', () {
      var b = TokenBudget(perSessionLimit: 1000);
      b = b.record(const TokenUsage(inputTokens: 800, outputTokens: 100));
      b = b.resetSession();
      expect(b.turnTotal, 0);
      expect(b.sessionTotal, 0);
    });

    test('per-session limit independent of per-turn', () {
      var b = TokenBudget(perTurnLimit: 1000, perSessionLimit: 1500);
      b = b.record(const TokenUsage(inputTokens: 500, outputTokens: 200));
      b = b.resetTurn();
      b = b.record(const TokenUsage(inputTokens: 500, outputTokens: 200));
      b = b.resetTurn();
      // Each turn was 700, never tripped per-turn. Cumulative 1400 < 1500.
      expect(b.exceeded(), isNull);
      b = b.record(const TokenUsage(inputTokens: 100, outputTokens: 100));
      // Now 1600 > 1500.
      expect(b.exceeded(), contains('per-session'));
    });

    test('checkRequestInput estimates from string lengths', () {
      // ~400 bytes of text → ~100 tokens at bytes/4. Limit at 50 trips.
      final big = 'x' * 400;
      final b = TokenBudget(perRequestInputLimit: 50);
      final reject = b.checkRequestInput(
        '',
        [
          Message(role: Role.user, content: [TextBlock(big)])
        ],
        const [],
      );
      expect(reject, contains('exceeds'));
    });

    test('checkRequestInput passes when under cap', () {
      final b = TokenBudget(perRequestInputLimit: 1000);
      final reject = b.checkRequestInput(
        'short system',
        [
          const Message(role: Role.user, content: [TextBlock('hi')])
        ],
        const [],
      );
      expect(reject, isNull);
    });

    test('estimateInputTokens approximates bytes/4 without a budget instance',
        () {
      // Same bytes/4 approximation as checkRequestInput, callable statically.
      final tokens = TokenBudget.estimateInputTokens(
        '',
        [
          Message(role: Role.user, content: [TextBlock('x' * 400)])
        ],
        const [],
      );
      expect(tokens, 100); // 400 bytes / 4
    });
  });

  group('Agent with TokenBudget', () {
    test('per-turn cap aborts mid-loop', () async {
      // Provider that always asks for another tool call so the agent loops.
      // Each turn reports 500 tokens of usage; cap at 1000 → trips on
      // the third response.
      final tools = ToolRegistry([FakeTool.noOp('fake')]);
      final provider = LoopingProvider(
        toolName: 'fake',
        usagePerTurn: const TokenUsage(inputTokens: 400, outputTokens: 100),
      );
      final budget = TokenBudget(perTurnLimit: 1000);
      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: PermissionPolicy(defaults: const {
          'fake': PermissionDecision.allow,
        }),
        asker: (_) async => PermissionResponse.allowOnce,
        budget: budget,
        system: 'sys',
      );

      await agent.run(history: <Message>[], userInput: 'loop');

      // Agent should have aborted before reaching maxSteps; check that we
      // stopped well under 50.
      expect(provider.callCount, lessThan(10),
          reason: 'budget should have halted the loop early');
      expect(agent.budget!.turnTotal, greaterThanOrEqualTo(1000));
    });

    test('per-request input cap aborts before sending', () async {
      // Pre-seed history with a huge tool result so the first pre-flight
      // check blows the cap and we never call the provider.
      final tools = ToolRegistry([FakeTool.noOp('fake')]);
      final provider = LoopingProvider(
        toolName: 'fake',
        usagePerTurn: const TokenUsage(inputTokens: 1, outputTokens: 1),
      );
      final budget = TokenBudget(perRequestInputLimit: 100);
      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        budget: budget,
        system: 'sys',
      );

      // 800 chars ~ 200 tokens, above the 100 cap.
      final huge = 'y' * 800;
      final history = <Message>[
        Message(role: Role.user, content: [TextBlock(huge)]),
      ];
      await agent.run(history: history, userInput: 'go');

      expect(provider.callCount, 0,
          reason: 'pre-flight should have prevented the request');
    });

    test('null content from provider does not crash the agent', () async {
      final provider = _BrokenStreamProvider();
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'sys',
      );

      // Before the fix, this would null-assert on outcome.content!.
      await expectLater(
        agent.run(history: <Message>[], userInput: 'x'),
        completes,
      );
    });
  });

  group('Agent per-session pause (PauseGate)', () {
    test('per-session trip pauses; Continue resets and resumes', () async {
      final tools = ToolRegistry([FakeTool.noOp('fake')]);
      final provider = _TripThenFinish(
          tripUsage: const TokenUsage(inputTokens: 400, outputTokens: 200));
      final budget = TokenBudget(perSessionLimit: 100); // 600 > 100 → trip
      final gate = PauseGate();
      var pauses = 0;
      // Auto-continue: when the agent requests a pause, immediately resume(true).
      gate.onPause.listen((_) {
        pauses++;
        gate.resume(continueDecision: true);
      });
      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: PermissionPolicy(
            defaults: const {'fake': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.allowOnce,
        budget: budget,
        pauseGate: gate,
        system: 'sys',
      );
      await agent.run(history: <Message>[], userInput: 'go');

      expect(pauses, 1, reason: 'the per-session trip paused once');
      expect(provider.callCount, 2,
          reason: 'resumed after Continue → the finishing call ran');
      expect(agent.budget!.sessionTotal, 2,
          reason: 'reset cleared the tripped total; only call 2 (2 tokens) '
              'remains');
    });

    test('per-session trip; Abort aborts the turn', () async {
      final tools = ToolRegistry([FakeTool.noOp('fake')]);
      final provider = _TripThenFinish(
          tripUsage: const TokenUsage(inputTokens: 400, outputTokens: 200));
      final budget = TokenBudget(perSessionLimit: 100);
      final gate = PauseGate();
      gate.onPause.listen((_) => gate.resume(continueDecision: false));
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: sink,
        policy: PermissionPolicy(
            defaults: const {'fake': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.allowOnce,
        budget: budget,
        pauseGate: gate,
        system: 'sys',
      );
      await agent.run(history: <Message>[], userInput: 'go');

      expect(provider.callCount, 1,
          reason: 'abort stops before the finishing call');
      expect(
          sink.notices.any((n) => n.message.contains('turn aborted')), isTrue);
    });

    test('per-turn trip still hard-aborts even with a gate (no pause)',
        () async {
      final tools = ToolRegistry([FakeTool.noOp('fake')]);
      final provider = LoopingProvider(
        toolName: 'fake',
        usagePerTurn: const TokenUsage(inputTokens: 400, outputTokens: 700),
      );
      final budget = TokenBudget(perTurnLimit: 500);
      final gate = PauseGate();
      var pauses = 0;
      gate.onPause.listen((_) => pauses++);
      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: FakeAgentSink(),
        policy: PermissionPolicy(
            defaults: const {'fake': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.allowOnce,
        budget: budget,
        pauseGate: gate,
        system: 'sys',
      );
      await agent.run(history: <Message>[], userInput: 'loop');

      expect(pauses, 0, reason: 'per-turn trips hard-abort, never pause');
      expect(provider.callCount, lessThan(10));
    });

    test('null gate + per-session trip hard-aborts (headless parity)',
        () async {
      final tools = ToolRegistry([FakeTool.noOp('fake')]);
      final provider = _TripThenFinish(
          tripUsage: const TokenUsage(inputTokens: 400, outputTokens: 200));
      final budget = TokenBudget(perSessionLimit: 100);
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: provider,
        tools: tools,
        sink: sink,
        policy: PermissionPolicy(
            defaults: const {'fake': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.allowOnce,
        budget: budget,
        system: 'sys',
      );
      await agent.run(history: <Message>[], userInput: 'go');

      expect(provider.callCount, 1, reason: 'legacy abort path, no resume');
      expect(
          sink.notices.any((n) => n.message.contains('per-session')), isTrue);
    });
  });
}

// --- test doubles --------------------------------------------------------

/// Yields no MessageComplete — simulates a server cutting the stream off
/// after handshake but before any usable response.
class _BrokenStreamProvider extends LlmProvider {
  _BrokenStreamProvider() : super('broken');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    // Stream completes without ever emitting MessageComplete.
    yield const TextDelta('partial');
  }
}

/// Call 1: a tool call carrying [tripUsage] (enough to trip a low per-session
/// budget). Call 2+: a final text answer. Used to exercise the pause/resume and
/// pause/abort paths deterministically (one trip, then finish).
class _TripThenFinish extends LlmProvider {
  int callCount = 0;
  final TokenUsage tripUsage;
  _TripThenFinish({required this.tripUsage}) : super('trip');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    callCount++;
    if (callCount == 1) {
      yield MessageComplete(
        content: [
          ToolUseBlock(id: 'u1', name: 'fake', input: const {}),
        ],
        stopReason: 'tool_use',
        usage: tripUsage,
      );
    } else {
      yield const MessageComplete(
        content: [TextBlock('done')],
        stopReason: 'end_turn',
        usage: TokenUsage(inputTokens: 1, outputTokens: 1),
      );
    }
  }
}
