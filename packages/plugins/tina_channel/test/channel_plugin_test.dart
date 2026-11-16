import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// The identity and scoping wiring: the plugin settles the sender
/// identity at session open — generated shortcode by default, explicit
/// override verbatim — opens the chat scoped to the SESSION (a
/// subagent child passes its parent's id), and the tools speak with
/// exactly that name.
void main() {
  PluginSession session(String id) => PluginSession(
        id: id,
        workingDirectory: '.',
        notifyChanged: () {},
      );

  test('default: the sender identity is the generated shortcode', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(openStore: (_) => store, role: 'main');
    expect(plugin.name, isNull); // nothing generated before open
    plugin.openSession(session('identity-test'));
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
        openStore: (_) => store, agentName: 'checkout-7', role: 'main');
    plugin.openSession(session('identity-test'));
    addTearDown(plugin.closeSession);

    expect(plugin.name, 'checkout-7');
    expect(store.read('#lobby').single.sender, 'checkout-7');
  });

  test('tool schemas appear once the session opens', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(openStore: (_) => store);
    expect(plugin.tools, isEmpty); // tools exist only with a session
    plugin.openSession(session('identity-test'));
    addTearDown(plugin.closeSession);
    expect(plugin.tools.map((t) => t.name),
        containsAll(['channel_say', 'channel_read', 'channel_status']));
    // The join announce above already proved the store-facing identity;
    // the tools receive the same name at construction.
    expect(store.members('#lobby').single.name, plugin.name);
  });

  test('closing the session clears the identity', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(openStore: (_) => store);
    plugin.openSession(session('identity-test'));
    expect(plugin.name, isNotNull);
    plugin.closeSession();
    expect(plugin.name, isNull);
  });

  test('the chat is scoped to the session: the opener gets the id', () {
    final store = InMemoryChannelStore();
    String? openedScope;
    final plugin = ChannelPlugin(
        openStore: (scope) {
          openedScope = scope;
          return store;
        },
        role: 'main');
    plugin.openSession(session('s-17'));
    addTearDown(plugin.closeSession);
    expect(openedScope, 's-17');
  });

  test('a subagent child joins the PARENT chat with role subagent', () {
    // The parent session's chat, already holding the main agent.
    final chat = InMemoryChannelStore();
    final parent = ChannelPlugin(
        openStore: (_) => chat, agentName: 'calm-heron', role: 'main');
    parent.openSession(session('parent-1'));
    addTearDown(parent.closeSession);

    // A child session: its own session id derives from the parent's,
    // but its chat scope IS the parent's id — the wiring the subagents
    // child factory mounts.
    final child = ChannelPlugin(
        openStore: (scope) {
          expect(scope, 'parent-1',
              reason: 'a child opens the parent session\'s chat');
          return chat;
        },
        chatSessionId: 'parent-1',
        role: 'subagent');
    child.openSession(session('parent-1-9182-child1'));
    addTearDown(child.closeSession);

    // One chat, two members: main agent + subagent with its own
    // generated shortcode (collision-checked against the parent's).
    final members = chat.members('#lobby');
    expect(members.map((m) => m.name), containsAll(['calm-heron', child.name]));
    expect(child.name, isNot('calm-heron'));
    expect(
        members
            .firstWhere((m) => m.name == child.name)
            .role,
        'subagent');
    expect(
        members.firstWhere((m) => m.name == 'calm-heron').role, 'main');
  });

  test('human + parent + child round trip in one chat', () {
    final chat = InMemoryChannelStore();
    final parent = ChannelPlugin(
        openStore: (_) => chat, agentName: 'parent-agent', role: 'main');
    parent.openSession(session('roundtrip'));
    addTearDown(parent.closeSession);
    final child = ChannelPlugin(
        openStore: (_) => chat,
        chatSessionId: 'roundtrip',
        agentName: 'child-agent',
        role: 'subagent');
    child.openSession(session('roundtrip-1-child1'));
    addTearDown(child.closeSession);
    humanJoin(chat, '#lobby', 'the-human', <String>{});

    chat.post('#lobby', sender: 'the-human', text: 'human here');
    chat.post('#lobby',
        sender: 'child-agent',
        text: 'found it — @parent-agent look',
        mentions: parseMentions('found it — @parent-agent look'));

    final messages = chat.read('#lobby');
    expect(messages.map((m) => m.sender),
        containsAllInOrder(['parent-agent', 'child-agent', 'the-human', 'child-agent']));
    final members = chat.members('#lobby').map((m) => (m.name, m.role));
    expect(members, contains(('parent-agent', 'main')));
    expect(members, contains(('child-agent', 'subagent')));
    expect(members, contains(('the-human', 'human')));
  });
}
