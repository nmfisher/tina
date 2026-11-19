import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

InMemoryChannelStore openMemory() => InMemoryChannelStore();

TurnContext _turn() => TurnContext(
      CancelToken(),
      input: const Input('test', id: 'i'),
      messages: const [],
      promptSections: [],
      pinnedTools: const [],
    );

/// The identity and scoping wiring: the plugin settles the sender
/// identity when the chat opens — generated shortcode by default,
/// explicit override verbatim — opens the chat scoped to the SESSION
/// (a subagent child passes its parent's id), and the tools speak with
/// exactly that name. A chat is OPT-IN now: these tests model a chat
/// that already exists (chatExists answers true, as a resumed session
/// would); the start/decline/dormant flows live in
/// channel_start_test.dart.
void main() {
  PluginSession session(String id) => PluginSession(
        id: id,
        workingDirectory: '.',
        notifyChanged: () {},
      );

  test('default: the sender identity is the generated shortcode', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(
        openStore: (_) => store, chatExists: (_) => true, role: 'main');
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
        openStore: (_) => store,
        chatExists: (_) => true,
        agentName: 'checkout-7',
        role: 'main');
    plugin.openSession(session('identity-test'));
    addTearDown(plugin.closeSession);

    expect(plugin.name, 'checkout-7');
    expect(store.read('#lobby').single.sender, 'checkout-7');
  });

  test('tool schemas appear once the session opens', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(
        openStore: (_) => store, chatExists: (_) => true);
    expect(plugin.tools, isEmpty); // tools exist only with a session
    plugin.openSession(session('identity-test'));
    addTearDown(plugin.closeSession);
    expect(plugin.tools.map((t) => t.name), containsAll([
      'channel_start',
      'channel_say',
      'channel_read',
      'channel_status',
      'channel_compact'
    ]));
    // The join announce above already proved the store-facing identity;
    // the tools receive the same name at construction.
    expect(store.members('#lobby').single.name, plugin.name);
  });

  test('closing the session clears the identity', () {
    final store = InMemoryChannelStore();
    final plugin = ChannelPlugin(
        openStore: (_) => store, chatExists: (_) => true);
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
        chatExists: (_) => true,
        role: 'main');
    plugin.openSession(session('s-17'));
    addTearDown(plugin.closeSession);
    expect(openedScope, 's-17');
  });

  test('a subagent child joins the PARENT chat with role subagent', () {
    // The parent session's chat, already holding the main agent.
    final chat = InMemoryChannelStore();
    final parent = ChannelPlugin(
        openStore: (_) => chat,
        chatExists: (_) => true,
        agentName: 'calm-heron',
        role: 'main');
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
        chatExists: (_) => true,
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
        openStore: (_) => chat,
        chatExists: (_) => true,
        agentName: 'parent-agent',
        role: 'main');
    parent.openSession(session('roundtrip'));
    addTearDown(parent.closeSession);
    final child = ChannelPlugin(
        openStore: (_) => chat,
        chatExists: (_) => true,
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

/// Phase 3 wiring: the plugin delivers at its turn boundary through the
/// prompt-section seam, and closing the session releases the watcher.
group('passive delivery', () {


  test('mention rides the next turn as a prompt section', () async {
    final other = openMemory();
    addTearDown(other.close);
    final plugin = ChannelPlugin(
      openStore: (_) => other,
      chatExists: (_) => true,
      agentName: 'calm-heron',
      role: 'main',
    );
    final session0 = session('delivery-test');
    plugin.openSession(session0);
    addTearDown(plugin.closeSession);
    other.post('#lobby',
        sender: 'busy-ox', text: '@calm-heron the build is green');
    final context = _turn();
    plugin.onPrompt(context);
    expect(context.promptSections.join('\n'), contains('build is green'));
    // Delivered once: the next turn carries nothing.
    final next = _turn();
    plugin.onPrompt(next);
    expect(
        next.promptSections.join('\n'), isNot(contains('build is green')));
  });

  test('closeSession releases the watcher (no delivery after close)',
      () async {
    final store = openMemory();
    final plugin = ChannelPlugin(
        openStore: (_) => store, chatExists: (_) => true, agentName: 'a');
    plugin.openSession(session('close-test'));
    plugin.closeSession();
    // The watcher is gone with the session: posts that arrive after
    // the close deliver to nobody — plugin hooks are inert, and the
    // watcher holds no timer or subscription of its own to leak.
    store.post('#lobby', sender: 'late', text: '@a too late');
    final context = _turn();
    plugin.onPrompt(context);
    expect(context.promptSections.join('\n'),
        isNot(contains('too late')));
  });
  });
}
