import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

/// Regression tests for #44 — aged large tool-result stubbing. A tool result
/// older than [kToolResultRetentionSteps] steps whose serialized body exceeds
/// [kToolResultStubThreshold] bytes is replaced IN PLACE with a short stub;
/// the `tool_use_id` and message structure stay intact so tool_use/result
/// pairing is NEVER severed (providers reject an unpaired use — the hard
/// invariant). #42 measured the cost this trims: one 53KB read re-sent for
/// the rest of a 45-step turn ≈ 585K cumulative tokens for content the model
/// had already metabolized on arrival.
///
/// The unit group drives [stubAgedToolResults] directly on constructed
/// histories; the integration group drives the full agent loop and asserts
/// the stubs reach the WIRE (the requests a provider actually receives),
/// silently (no notice — the UI showed the content live on arrival).
void main() {
  Message use(String id) => Message(
      role: Role.assistant, content: [ToolUseBlock(id: id, name: 'big', input: const {})]);
  Message result(String id, String body) => Message(
      role: Role.user,
      content: [ToolResultBlock(toolUseId: id, content: body)]);

  /// History of [n] use/result batches; batch [i]'s body comes from [bodyFor].
  List<Message> batches(int n, String Function(int i) bodyFor) {
    final history = <Message>[Message(role: Role.user, content: [TextBlock('go')])];
    for (var i = 1; i <= n; i++) {
      history..add(use('t$i'))..add(result('t$i', bodyFor(i)));
    }
    return history;
  }

  group('stubAgedToolResults (#44 unit)', () {
    test('an old LARGE result is stubbed: size shrinks, id and pairing survive', () {
      final history = batches(12, (i) => i == 1 ? 'y' * 5000 : 'ok');
      final stubbed = stubAgedToolResults(history, currentStep: 12);

      expect(stubbed, 1, reason: 'only batch 1 is both old (age 11) and large');
      final block = history[2].content.single as ToolResultBlock; // batch 1's result
      expect(block.toolUseId, 't1', reason: 'the id is preserved — pairing intact');
      expect(block.content,
          '[elided after 11 steps: big result, 5000 bytes — re-run to recover]');
      expect(block.content.length, lessThan(100));
      // Pairing invariant over the whole history: every use still has its
      // result and vice versa, by id.
      final useIds = history
          .where((m) => m.role == Role.assistant)
          .expand((m) => m.content)
          .whereType<ToolUseBlock>()
          .map((b) => b.id)
          .toSet();
      final resultIds = history
          .where((m) => m.role == Role.user)
          .expand((m) => m.content)
          .whereType<ToolResultBlock>()
          .map((b) => b.toolUseId)
          .toSet();
      expect(useIds, resultIds);
    });

    test('a RECENT large result is untouched (inside the retention window)', () {
      final history = batches(12, (i) => i == 12 ? 'y' * 5000 : 'ok');
      expect(stubAgedToolResults(history, currentStep: 12), 0);
      // Batch 12's result message sits at index 2×12 = 24 (index 0 is 'go').
      expect((history[24].content.single as ToolResultBlock).content.length, 5000,
          reason: 'batch 12 is age 0 — the current step is never touched');
    });

    test('the age boundary: age exactly kToolResultRetentionSteps stays, age +1 stubs', () {
      // Batch 4 of a 12-step turn: age 12 - 4 = 8 = the window — kept.
      var history = batches(12, (i) => i == 4 ? 'y' * 5000 : 'ok');
      expect(stubAgedToolResults(history, currentStep: 12), 0,
          reason: 'age == retention window is still "inside" it');
      // Batch 3: age 9 — one past the window — stubbed.
      history = batches(12, (i) => i == 3 ? 'y' * 5000 : 'ok');
      expect(stubAgedToolResults(history, currentStep: 12), 1);
    });

    test('the size boundary: exactly the threshold stays, one byte over stubs', () {
      var history = batches(12, (i) => i == 1 ? 'y' * kToolResultStubThreshold : 'ok');
      expect(stubAgedToolResults(history, currentStep: 12), 0,
          reason: 'threshold is a minimum EXCEEDED, not met');
      history = batches(12, (i) => i == 1 ? 'y' * (kToolResultStubThreshold + 1) : 'ok');
      expect(stubAgedToolResults(history, currentStep: 12), 1);
      final bytes = (history[2].content.single as ToolResultBlock).content;
      expect(bytes, contains('${kToolResultStubThreshold + 1} bytes'));
    });

    test('a SMALL old result is untouched', () {
      final history = batches(12, (_) => 'ok');
      expect(stubAgedToolResults(history, currentStep: 12), 0,
          reason: 'all-small history is a no-op');
    });

    test('isError results keep their error flag through the stub', () {
      final history = batches(12, (i) => i == 1 ? 'y' * 5000 : 'ok');
      history[2] = Message(
          role: Role.user,
          content: [ToolResultBlock(toolUseId: 't1', isError: true, content: 'y' * 5000)]);
      stubAgedToolResults(history, currentStep: 12);
      expect((history[2].content.single as ToolResultBlock).isError, isTrue);
    });

    test('a result whose use was summarized away stubs as "unknown tool"', () {
      // Post-compaction histories can carry a result whose producing
      // tool_use no longer exists; the lookup falls back rather than
      // severing or crashing. The ghost REPLACES the use message at
      // index 1, leaving [go, ghost-result, res t1].
      final history = batches(1, (_) => 'y' * 5000);
      history[1] = Message(
          role: Role.user,
          content: [ToolResultBlock(toolUseId: 'ghost', content: 'y' * 5000)]);
      expect(stubAgedToolResults(history, currentStep: 10), 1);
      expect((history[1].content.single as ToolResultBlock).content,
          contains('unknown tool'));
    });

    test('all-recent history is a no-op even when everything is large', () {
      final history = batches(5, (_) => 'y' * 5000);
      expect(stubAgedToolResults(history, currentStep: 5), 0,
          reason: 'ages 4..0 — all inside the window');
    });
  });

  group('Agent.run aged tool-result stubbing (#44 integration)', () {
    // autoCompactThreshold = 0 isolates stubbing from compaction: the stub
    // pass runs before and OUTSIDE the compaction gate, so the wire below
    // shows pure stubbing with no summarizer request ever sent.
    test('stubs reach the wire silently, pairing intact, recent results full', () async {
      List<StreamEvent> round(String id) => [
            MessageComplete(
              content: [ToolUseBlock(id: id, name: 'big', input: const {})],
              stopReason: 'tool_use',
              usage: const TokenUsage(inputTokens: 20, outputTokens: 20),
            ),
          ];
      final provider = FakeProvider([
        for (var i = 1; i <= 11; i++) round('t$i'),
        const [
          TextDelta('done'),
          MessageComplete(content: [TextBlock('done')], stopReason: 'end_turn'),
        ],
      ]);
      final sink = FakeAgentSink();
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('big', (_) => ToolResult('z' * 5000)),
        ]),
        sink: sink,
        policy: PermissionPolicy(defaults: {'big': PermissionDecision.allow}),
        asker: (_) async => PermissionResponse.allowOnce,
        maxSteps: 20,
        system: 'sys',
      );
      agent.autoCompactThreshold = 0;

      await agent.run(history: <Message>[], userInput: 'go');

      // Round 10's request is the FIRST that can carry a stub: at its
      // step-top checkpoint batch 1 is age 10 - 1 = 9, one past the window.
      final wire = provider.calls[9].messages;
      final t1 = wire
          .expand((m) => m.content)
          .whereType<ToolResultBlock>()
          .firstWhere((b) => b.toolUseId == 't1');
      expect(t1.content,
          '[elided after 9 steps: big result, 5000 bytes — re-run to recover]',
          reason: 'the aged large result is stubbed ON the wire');
      // A recent result on the SAME request rides at full size.
      final t9 = wire
          .expand((m) => m.content)
          .whereType<ToolResultBlock>()
          .firstWhere((b) => b.toolUseId == 't9');
      expect(t9.content.length, 5000);
      // Pairing invariant ON the wire: every use in the request has its
      // result and no result lost its id.
      final useIds = wire
          .where((m) => m.role == Role.assistant)
          .expand((m) => m.content)
          .whereType<ToolUseBlock>()
          .map((b) => b.id)
          .toSet();
      final resultIds = wire
          .expand((m) => m.content)
          .whereType<ToolResultBlock>()
          .map((b) => b.toolUseId)
          .toSet();
      expect(useIds.difference(resultIds), isEmpty,
          reason: 'no tool_use may lose its result');
      // Silent by design: the UI showed the content live when it arrived.
      expect(sink.notices.any((n) => n.message.contains('elided')), isFalse);
      // The turn completed normally — stubbing never interferes.
      expect(agent.abortedReason, isNull);
    });
  });
}
