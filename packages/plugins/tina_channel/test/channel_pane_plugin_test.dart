import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

void main() {
  test('opens and closes the injected store with the session', () {
    final store = InMemoryChannelStore();
    var opened = 0;
    final plugin = ChannelPanePlugin(openStore: () {
      opened++;
      return store;
    });
    expect(plugin.id, 'tina/channel-tui');
    expect(plugin.storeForView, isNull);
    plugin.openSession(PluginSession(
      id: 'test-session',
      workingDirectory: '.',
      notifyChanged: () {},
    ));
    expect(plugin.storeForView, same(store));
    plugin.closeSession();
    expect(plugin.storeForView, isNull);
    expect(opened, 1);
  });
}
