import 'package:test/test.dart';
import 'package:tina_activity/tina_activity.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

final class _Terminal implements Terminal {
  final lines = <String>[];
  @override
  void writeln([String? line]) => lines.add(line ?? '');
  @override
  Future<String> ask(String prompt) async => '';
}

void main() {
  test(
    'activity owns observations and its command has a headless fallback',
    () async {
      final terminal = _Terminal();
      final activity = ActivityPlugin(
        terminal: terminal,
        printTranscript: false,
      );
      final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('done')]),
        plugins: [activity],
      );
      activity.mountOn(loop);
      final seen = <SessionObservationEvent>[];
      final release = activity.observation.listen(seen.add);
      release();
      expect(
        (await loop.runTurn(const Input('go', id: 'turn'))).stopReason,
        StopReason.complete,
      );
      expect(seen, isEmpty);
      final replay = <SessionObservationEvent>[];
      activity.observation.listen(replay.add);
      expect(replay.whereType<ObservedEntry>(), hasLength(loop.log.length));
      await activity.commands.single.handler('');
      expect(terminal.lines.single, contains('interactive console'));
      activity.closeSession();
      expect(() => activity.observation.listen((_) {}), throwsStateError);
    },
  );
}
