import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

void main() {
  test('signed reasoning survives the log round trip and the next request',
      () async {
    final provider = ScriptedProvider([
      [
        const ReasoningDelta('one', startsBlock: true),
        const ReasoningDelta(' thought'),
        const ReasoningEnd(signature: 'provider-signature'),
        ...scriptedReply('answer')
      ],
    ]);
    final loop = AgentLoop(provider: provider, plugins: []);
    await loop.runTurn(const Input('first', id: 'first'));
    final seed =
        loop.log.map((e) => SessionEntry.fromJson(e.toJson())).toList();
    final resumedProvider = ScriptedProvider([scriptedReply('next')]);
    final resumed =
        AgentLoop(provider: resumedProvider, plugins: [], seedLog: seed);
    await resumed.runTurn(const Input('next', id: 'next'));
    final reply = resumedProvider.requests.single.messages
        .where((m) => m.role == Role.assistant)
        .single;
    expect(reply.reasoning.single.text, 'one thought');
    expect(reply.reasoning.single.complete, true);
    expect(reply.reasoning.single.signature, 'provider-signature');
  });
  test('interrupted reasoning stays inspectable and explicitly partial',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          [
            const ReasoningDelta('unfinished', startsBlock: true),
            const StreamError('interrupted')
          ],
        ]),
        plugins: []);
    await loop.runTurn(const Input('first', id: 'first'));
    final reply = loop.log
        .whereType<MessageAppendedEntry>()
        .map((e) => e.message)
        .where((m) => m.role == Role.assistant)
        .single;
    expect(reply.content, isEmpty);
    expect(reply.reasoning.single.text, 'unfinished');
    expect(reply.reasoning.single.complete, false);
    expect(reply.reasoning.single.signature, isNull);
    expect((loop.log.last as TurnEndedEntry).reason, TurnStopReason.error);
  });
}
