import 'package:tina_persistence/tina_persistence.dart';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class ProbePlugin extends AgentPlugin {
  ProbePlugin(this.id);
  @override
  final String id;
  final mounts = <AgentLoop>[];
  final arguments = <String>[];

  @override
  void mountOn(AgentLoop loop) => mounts.add(loop);

  @override
  List<Command> get commands => [
        Command(
            name: 'probe',
            description: 'probe',
            handler: (argument) async {
              await Future<void>.delayed(Duration.zero);
              arguments.add(argument);
            }),
      ];
}

void main() {
  test('start and resume mount plugins and collect their async commands',
      () async {
    final dir = Directory.systemTemp.createTempSync('host-plugin-');
    addTearDown(() => dir.deleteSync(recursive: true));
    HostConfig config(ProbePlugin plugin) => HostConfig(
          workingDirectory: dir.path,
          providerFactory: (_) => ScriptedProvider([scriptedReply('hello')]),
          plugins: [
            plugin,
            PersistencePlugin(
                openStore: () => SessionStore.open('${dir.path}/sessions.db')),
          ],
        );
    final first = ProbePlugin('test/first');
    final host = Host.start(config(first), sessionId: 'session');
    addTearDown(host.close);
    expect(first.mounts, [host.session.loop]);
    await host.commands['probe']!.handler('first');
    expect(first.arguments, ['first']);
    await host.send('hello');
    final historyLength = host.session.loop.log.length;
    host.close();

    final second = ProbePlugin('test/second');
    final resumed = Host.resume(config(second), 'session');
    addTearDown(resumed.close);
    expect(second.mounts, [resumed.session.loop]);
    expect(second.mounts.single.log, hasLength(historyLength));
    await resumed.commands['probe']!.handler('resumed');
    expect(second.arguments, ['resumed']);
    expect(first.arguments, ['first']);
  });

  test('duplicate commands fail before opening a provider or mounting plugins',
      () {
    var builds = 0;
    final first = ProbePlugin('test/first');
    final second = ProbePlugin('test/second');
    expect(
        () => Host.start(HostConfig(
              workingDirectory: '.',
              providerFactory: (_) {
                builds++;
                return ScriptedProvider([]);
              },
              plugins: [first, second],
            )),
        throwsStateError);
    expect(builds, 0);
    expect(first.mounts, isEmpty);
    expect(second.mounts, isEmpty);
  });
}
