import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class LifecyclePlugin extends AgentPlugin {
  LifecyclePlugin(this.id, this.events,
      {this.failOpen = false, this.failClose = false});
  @override
  final String id;
  final List<String> events;
  final bool failOpen;
  final bool failClose;
  @override
  SessionSeed? openSession(PluginSession session) {
    events.add('open $id');
    if (failOpen) throw StateError('open failed');
    return null;
  }

  @override
  void closeSession() {
    events.add('close $id');
    if (failClose) throw StateError('close failed');
  }
}

void main() {
  test('partial opening failures close attempted plugins in reverse order', () {
    final events = <String>[];
    var built = false;
    expect(
        () => Host.start(HostConfig(
              workingDirectory: '.',
              plugins: [
                LifecyclePlugin('test/a', events),
                LifecyclePlugin('test/b', events, failOpen: true),
                LifecyclePlugin('test/c', events)
              ],
              providerFactory: (_) {
                built = true;
                return ScriptedProvider([]);
              },
            )),
        throwsStateError);
    expect(built, isFalse);
    expect(
        events, ['open test/a', 'open test/b', 'close test/b', 'close test/a']);
  });

  test('closing attempts every plugin once even when one throws', () {
    final events = <String>[];
    final host = Host.start(HostConfig(
      workingDirectory: '.',
      providerFactory: (_) => ScriptedProvider([]),
      plugins: [
        LifecyclePlugin('test/a', events),
        LifecyclePlugin('test/b', events, failClose: true)
      ],
    ));
    expect(host.close, throwsStateError);
    expect(
        events, ['open test/a', 'open test/b', 'close test/b', 'close test/a']);
    host.close();
    expect(events, hasLength(4));
  });
}
