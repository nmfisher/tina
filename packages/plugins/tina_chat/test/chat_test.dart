import 'package:test/test.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

void main() {
  test(
    'session metadata is dynamic and replay remains available without a view',
    () async {
      var cap = 10, tokens = 2;
      final chat = ChatPlugin(
        model: 'fallback',
        currentTokenCap: () => cap,
        sessionTokens: () => tokens,
        terminalAlertsEnabled: () => false,
      );
      chat.openSession(
        PluginSession(
          id: 'session',
          workingDirectory: '/tmp',
          notifyChanged: () {},
        ),
      );
      final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('hello')]),
        plugins: [chat],
      );
      chat.mountOn(loop);
      addTearDown(chat.closeSession);
      expect(
        (await loop.runTurn(const Input('go', id: 'turn'))).stopReason,
        StopReason.complete,
      );
      final events = <SessionObservationEvent>[];
      chat.observation.events.listen(events.add);
      expect(events.whereType<ObservedEntry>(), hasLength(loop.log.length));
      cap = 20;
      tokens = 7;
      expect(chat.observation.tokenCap, 20);
      expect(chat.observation.sessionTokens, 7);
      expect(chat.observation.sessionId, 'session');
      expect(chat.observation.terminalAlertsEnabled, false);
      chat.closeSession();
      expect(() => chat.observation.events.listen((_) {}), throwsStateError);
    },
  );

  test('unattached model previews replay independently to each subscriber', () async {
    final chat = ChatPlugin(model: 'fallback');
    addTearDown(chat.closeSession);
    chat.watch(const SawThinking('thought', startsBlock: true));
    chat.watch(const SawText('partial'));
    final first = <SessionObservationEvent>[],
        second = <SessionObservationEvent>[];
    final release = chat.observation.events.listen(first.add);
    chat.observation.events.listen(second.add);
    expect(first, second);
    release();
    chat.watch(const SawText(' more'));
    expect(first, hasLength(2));
    expect(second, hasLength(2), reason: 'live callbacks are deferred');
    await Future<void>.delayed(Duration.zero);
    expect(second, hasLength(3));
  });
}
