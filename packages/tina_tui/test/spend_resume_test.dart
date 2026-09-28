import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  test('SQLite resume preserves failed spend and enforces the combined ceiling',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-spend-resume-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final config = File('${dir.path}/config');
    void configure([int cap = 0]) => config.writeAsStringSync('''
[default]
model="test"
[plugins]
enabled=["tina/persistence", "tina/chat-tui"]
[limits]
max_session_tokens=$cap
''');
    configure();
    final initial = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: dir.path),
        providerFactory: (_) => ScriptedProvider([
              [const StreamError('transport failed')],
              [
                const MessageComplete(
                    content: [TextBlock('done')],
                    stopReason: 'end_turn',
                    usage: TokenUsage(inputTokens: 3, outputTokens: 2))
              ],
            ]));
    await initial.host.send('first');
    await initial.host.send('second');
    final spend = initial.host.plugins.whereType<ProviderPolicyPlugin>().single;
    final measured = spend.sessionTokens;
    final estimated = spend.sessionEstimatedTokens;
    expect(measured, 5);
    expect(estimated, greaterThan(0));
    final id = initial.host.session.id;
    final store =
        initial.host.plugins.whereType<PersistencePlugin>().single.store;
    expect(store.readEntries(id).whereType<UsageRecordedEntry>(), hasLength(2));
    initial.close();
    configure(measured + estimated);
    final resumed = TuiAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: dir.path, sessionId: id),
        providerFactory: (_) =>
            ScriptedProvider([scriptedReply('must not run')]));
    addTearDown(resumed.close);
    final restored =
        resumed.host.plugins.whereType<ProviderPolicyPlugin>().single;
    expect(restored.sessionTokens, measured);
    expect(restored.sessionEstimatedTokens, estimated);
    await resumed.host.send('third');
    final ended =
        resumed.host.session.loop.log.whereType<TurnEndedEntry>().last;
    expect(ended.reason, isNot(TurnStopReason.complete));
    expect(restored.sessionTokens, measured);
    expect(restored.sessionEstimatedTokens, estimated);
  });
}
