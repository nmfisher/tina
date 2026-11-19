import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

void main() {
  PluginSession session(String id) => PluginSession(
        id: id,
        workingDirectory: '.',
        notifyChanged: () {},
      );

  test('dormant until the session\'s chat is started, then opens once',
      () async {
    final store = InMemoryChannelStore();
    String? openedScope;
    var opened = 0;
    final chat = SessionChat();
    final plugin = ChannelPanePlugin(openStore: (scope) {
      opened++;
      openedScope = scope;
      return store;
    }, chat: chat);
    expect(plugin.id, 'tina/channel-tui');

    // The chat is opt-in: opening the session creates nothing.
    plugin.openSession(session('test-session'));
    expect(plugin.storeForView, isNull);
    expect(plugin.chatForView.store, isNull);
    expect(plugin.chatForView.isStarted, isFalse);
    expect(opened, 0);

    // The channel plugin starts the chat (the user approved one) and
    // signals it through the shared lifecycle.
    chat.markStarted();
    await pumpEventQueue();
    // The pane shows THIS session's chat — the opener receives the
    // session's own id, exactly once.
    expect(openedScope, 'test-session');
    expect(opened, 1);
    expect(plugin.storeForView, same(store));
    expect(plugin.chatForView.store, same(store));
    expect(plugin.chatForView.isStarted, isTrue);

    // Repeated signals (idempotent start paths) open nothing more.
    chat.markStarted();
    await pumpEventQueue();
    expect(opened, 1);

    plugin.closeSession();
    expect(plugin.storeForView, isNull);
    expect(plugin.chatForView.store, isNull);
  });

  test('a chat that already exists attaches at session open', () {
    // Resume: the channel plugin found the chat before the pane opened
    // (plugin order), so the pane attaches immediately.
    final store = InMemoryChannelStore();
    final chat = SessionChat()..markStarted();
    final plugin =
        ChannelPanePlugin(openStore: (_) => store, chat: chat);
    plugin.openSession(session('resume-me'));
    expect(plugin.storeForView, same(store));
    expect(plugin.chatForView.isStarted, isTrue);
    plugin.closeSession();
  });

  test('closing before any start opens nothing', () {
    var opened = 0;
    final plugin = ChannelPanePlugin(
        openStore: (_) {
          opened++;
          return InMemoryChannelStore();
        },
        chat: SessionChat());
    plugin.openSession(session('never-started'));
    plugin.closeSession();
    expect(opened, 0);
  });
}
