import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

void main() {
  test('opens the session\'s chat with the session and closes it', () {
    final store = InMemoryChannelStore();
    String? openedScope;
    var opened = 0;
    final plugin = ChannelPanePlugin(openStore: (scope) {
      opened++;
      openedScope = scope;
      return store;
    });
    expect(plugin.id, 'tina/channel-tui');
    expect(plugin.storeForView, isNull);
    plugin.openSession(PluginSession(
      id: 'test-session',
      workingDirectory: '.',
      notifyChanged: () {},
    ));
    // The pane shows THIS session's chat — the opener receives the
    // session's own id.
    expect(openedScope, 'test-session');
    expect(plugin.storeForView, same(store));
    plugin.closeSession();
    expect(plugin.storeForView, isNull);
    expect(opened, 1);
  });
}
