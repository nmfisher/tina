import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// The identity wiring: the plugin settles the sender identity at
/// session open — generated shortcode by default, explicit override
/// verbatim — and the tools speak with exactly that name.
void main() {
  PluginSession session() => PluginSession(
        id: 'identity-test',
        workingDirectory: '.',
        notifyChanged: () {},
      );

  test('default: the sender identity is the generated shortcode', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(openStore: () => store, role: 'main');
    expect(plugin.name, isNull); // nothing generated before open
    plugin.openSession(session());
    addTearDown(plugin.closeSession);

    final name = plugin.name!;
    expect(name, matches(RegExp(r'^[a-z]+-[a-z]+$')));
    expect(isBareShortcode(name), isTrue);

    // The join announce carries the shortcode as sender, the role in
    // the member row — never in the name.
    final join = store.read('#lobby').single;
    expect(join.sender, name);
    expect(join.type, ChannelMessageType.status);
    final member = store.members('#lobby').single;
    expect(member.name, name);
    expect(member.role, 'main');
    expect(member.status, 'working');
  });

  test('explicit agentName is used verbatim, generation skipped', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(
        openStore: () => store, agentName: 'checkout-7', role: 'main');
    plugin.openSession(session());
    addTearDown(plugin.closeSession);

    expect(plugin.name, 'checkout-7');
    expect(store.read('#lobby').single.sender, 'checkout-7');
  });

  test('tool schemas appear once the session opens', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(openStore: () => store);
    expect(plugin.tools, isEmpty); // tools exist only with a session
    plugin.openSession(session());
    addTearDown(plugin.closeSession);
    expect(plugin.tools.map((t) => t.name),
        containsAll(['channel_say', 'channel_read', 'channel_status']));
    // The join announce above already proved the store-facing identity;
    // the tools receive the same name at construction.
    expect(store.members('#lobby').single.name, plugin.name);
  });

  test('closing the session clears the identity', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(openStore: () => store);
    plugin.openSession(session());
    expect(plugin.name, isNotNull);
    plugin.closeSession();
    expect(plugin.name, isNull);
  });
}
