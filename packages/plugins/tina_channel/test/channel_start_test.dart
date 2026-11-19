import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

TurnContext _turn() => TurnContext(
      CancelToken(),
      input: const Input('test', id: 'i'),
      messages: const [],
      promptSections: [],
      pinnedTools: const [],
    );

/// The opt-in start: `channel_start` is a PROPOSAL the user decides.
/// Before an approval nothing exists — no room, no pane signal, no
/// answered tools. An approval creates the store, the channel, the
/// memberships; a decline creates nothing and may not be re-asked in
/// the same user turn. Subagents never start rooms; a chat that
/// already exists (found at open, or a second call) is reported, not
/// duplicated.
void main() {
  PluginSession session(String id) => PluginSession(
        id: id,
        workingDirectory: '.',
        notifyChanged: () {},
      );

  late InMemoryChannelStore store;
  ChannelPlugin makePlugin({
    String role = 'main',
    bool exists = false,
    ChannelStartApprover? approve,
  }) =>
      ChannelPlugin(
        openStore: (_) => store,
        chatExists: (_) => exists,
        agentName: 'calm-heron',
        role: role,
        humanName: 'sam',
        approveStart: approve,
      );

  setUp(() => store = InMemoryChannelStore());

  test('a fresh session is dormant: no room, tools refuse, no signal',
      () async {
    final plugin = makePlugin();
    plugin.openSession(session('fresh'));
    addTearDown(plugin.closeSession);

    expect(plugin.isStarted, isFalse);
    expect(plugin.name, isNull);
    expect(plugin.storeForUi, isNull);
    expect(plugin.isStarted, isFalse); // the pane learns nothing
    // Nothing was written: no members, no messages (the store's own
    // #lobby channel placeholder is not a created room).
    expect(store.members('#lobby'), isEmpty);
    expect(store.read('#lobby'), isEmpty);

    // The toolset is stable (advertised) but every channel tool
    // answers with the not-started refusal.
    expect(
        plugin.tools.map((t) => t.name), contains('channel_start'));
    for (final name in ['channel_say', 'channel_read', 'channel_status']) {
      final result =
          await plugin.execute(name, {'channel': '#lobby', 'text': 'hi'});
      expect(result.isError, isTrue, reason: name);
      expect(result.content, contains('No group chat has been started'));
    }

    // The prompt section says what is missing and how one may start.
    final context = _turn();
    plugin.onPrompt(context);
    expect(context.promptSections.join('\n'),
        contains('No group chat exists for this session yet'));
  });

  test('approval granted: store created, members joined, pane signaled',
      () async {
    String? askedChannel;
    String? askedPurpose;
    String? askedMembers;
    final plugin = makePlugin(approve: ({required channel, purpose, required members}) async {
      askedChannel = channel;
      askedPurpose = purpose;
      askedMembers = members;
      return true;
    });
    plugin.openSession(session('start-me'));
    addTearDown(plugin.closeSession);

    final result = await plugin.execute('channel_start', {
      'channel': 'warroom',
      'purpose': 'coordinate the release checks',
    });
    expect(result.isError, isFalse, reason: result.content);

    // The approval saw exactly what is being created.
    expect(askedChannel, '#warroom');
    expect(askedPurpose, 'coordinate the release checks');
    expect(askedMembers, contains('sam'));
    expect(askedMembers, contains('subagents'));

    // Store, channel, memberships: main agent announced, human row
    // recorded (silently — the pane announces on first view).
    expect(plugin.isStarted, isTrue);
    expect(plugin.isStarted, isTrue); // the pane goes live
    expect(store.listChannels().map((c) => c.name),
        containsAll(['#lobby', '#warroom']));
    final war = store.members('#warroom');
    expect(war.map((m) => m.name), containsAll(['calm-heron', 'sam']));
    expect(war.firstWhere((m) => m.name == 'calm-heron').role, 'main');
    expect(war.firstWhere((m) => m.name == 'sam').role, 'human');
    final lobby = store.members('#lobby');
    expect(lobby.map((m) => m.name), containsAll(['calm-heron', 'sam']));
    // No announce row for the human anywhere: exactly one status
    // announce per agent-joined channel.
    for (final channel in ['#lobby', '#warroom']) {
      expect(
          store
              .read(channel)
              .where((m) => m.type == ChannelMessageType.status)
              .map((m) => m.sender),
          everyElement('calm-heron'));
    }

    // The tools work now, and the active prompt section is back.
    final said = await plugin.execute('channel_say',
        {'channel': 'warroom', 'text': 'first post'});
    expect(said.isError, isFalse);
    expect(store.read('#warroom').last.text, 'first post');
    final context = _turn();
    plugin.onPrompt(context);
    expect(context.promptSections.join('\n'),
        contains('Coordination channels are available'));
  });

  test('approval declined: nothing created, refusal, no re-ask this turn',
      () async {
    var asks = 0;
    final plugin = makePlugin(approve: ({required channel, purpose, required members}) async {
      asks++;
      return false;
    });
    plugin.openSession(session('declined'));
    addTearDown(plugin.closeSession);

    final result = await plugin.execute('channel_start', {});
    expect(result.isError, isTrue);
    expect(result.content, contains('declined'));
    expect(plugin.isStarted, isFalse);
    expect(plugin.isStarted, isFalse);
    expect(store.members('#lobby'), isEmpty);
    expect(store.read('#lobby'), isEmpty);

    // Re-ask in the same user turn: refused WITHOUT a new approval.
    final reask = await plugin.execute('channel_start', {});
    expect(reask.isError, isTrue);
    expect(reask.content, contains('already declined'));
    expect(asks, 1);

    // A later user turn may ask again (the etiquette is one ask per
    // user turn, not ever).
    plugin.onPrompt(_turn());
    final later = await plugin.execute('channel_start', {});
    expect(later.isError, isTrue);
    expect(later.content, contains('declined'));
    expect(asks, 2);
    expect(plugin.isStarted, isFalse);
  });

  test('a subagent call is refused without asking the user', () async {
    var asks = 0;
    final plugin = makePlugin(
        role: 'subagent',
        approve: ({required channel, purpose, required members}) async {
          asks++;
          return true;
        });
    plugin.openSession(session('child'));
    addTearDown(plugin.closeSession);

    final result = await plugin.execute('channel_start', {});
    expect(result.isError, isTrue);
    expect(result.content, contains('Only the main agent'));
    expect(asks, 0);
    expect(plugin.isStarted, isFalse);
    expect(store.members('#lobby'), isEmpty);
  });

  test('idempotent: an already-started chat is reported, not duplicated',
      () async {
    final plugin = makePlugin(approve: ({required channel, purpose, required members}) async {
      return true;
    });
    plugin.openSession(session('once'));
    addTearDown(plugin.closeSession);

    final first = await plugin.execute('channel_start', {});
    expect(first.isError, isFalse);
    final membersAfterStart = store.members('#lobby').length;
    final messagesAfterStart = store.read('#lobby').length;

    final second = await plugin.execute('channel_start', {});
    expect(second.isError, isFalse);
    expect(second.content, contains('already started'));
    expect(store.members('#lobby').length, membersAfterStart);
    expect(store.read('#lobby').length, messagesAfterStart);
  });

  test('a chat that already exists reattaches at open (resume)', () async {
    // A previous run of this session started a chat; the file exists.
    final plugin = makePlugin(exists: true);
    plugin.openSession(session('resumed'));
    addTearDown(plugin.closeSession);

    expect(plugin.isStarted, isTrue);
    expect(plugin.isStarted, isTrue); // the pane attaches at open
    expect(plugin.name, 'calm-heron'); // identity settled
    expect(store.members('#lobby').single.role, 'main');

    // channel_start reports the existing chat instead of duplicating
    // (and never asks: no approver is wired on this plugin).
    final result =
        await plugin.execute('channel_start', <String, Object?>{});
    expect(result.isError, isFalse);
    expect(result.content, contains('already started'));
  });

  test('a subagent spawned before the chat starts notices at its turn',
      () {
    var exists = false;
    final child = ChannelPlugin(
      openStore: (_) => store,
      chatExists: (_) => exists,
      chatSessionId: 'parent',
      agentName: 'child-agent',
      role: 'subagent',
      humanName: 'sam',
    );
    child.openSession(session('parent-1-child'));
    addTearDown(child.closeSession);
    expect(child.isStarted, isFalse);

    // The parent starts the chat (a run of the parent process).
    store.setMember('#lobby', 'calm-heron',
        status: 'working', role: 'main');
    exists = true;

    // The child's next turn boundary reattaches it to the chat.
    child.onPrompt(_turn());
    expect(child.isStarted, isTrue);
    expect(store.members('#lobby').map((m) => m.name),
        containsAll(['calm-heron', 'child-agent']));
  });

  test('no approval path: starting is refused, nothing created', () async {
    final plugin = makePlugin();
    plugin.openSession(session('no-approver'));
    addTearDown(plugin.closeSession);

    final result = await plugin.execute('channel_start', {});
    expect(result.isError, isTrue);
    expect(result.content, contains('approval'));
    expect(plugin.isStarted, isFalse);
  });

  test('input validation: bad channel and oversized purpose', () async {
    final plugin = makePlugin(approve: ({required channel, purpose, required members}) async {
      fail('validation must refuse before asking');
    });
    plugin.openSession(session('validate'));
    addTearDown(plugin.closeSession);

    final badChannel =
        await plugin.execute('channel_start', {'channel': 'a b'});
    expect(badChannel.isError, isTrue);
    final longPurpose = await plugin.execute('channel_start', {
      'purpose': 'x' * 201,
    });
    expect(longPurpose.isError, isTrue);
    expect(plugin.isStarted, isFalse);
  });
}
