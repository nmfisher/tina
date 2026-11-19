/// Sub-agent mode vs swarm mode: `launch_subagent`'s spawn-time
/// `channel` choice (default false). Everything runs through the real
/// pieces — a parent host, the plugin, [standardChildFactory] — with a
/// real channel plugin (over the in-memory store twin) as the swarm
/// participant wiring, exactly as plugin_catalog mounts it.
///
/// The scoping rule is asserted at the MEMBERSHIP level: an
/// independent child never becomes a member of any channel (and its
/// model request carries no channel tools and no channel prompt
/// section, so no watcher and no deliveries can exist), while a
/// participant joins as a `subagent` member, gets the tools, the
/// etiquette section, and can post.
library;

import 'dart:io';

import 'package:tina_channel/tina_channel.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_subagents/tina_subagents.dart';
import 'harness.dart' show workspace;
import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

void main() {
  // The session's chat: exists (started, user-approved) or not.
  late InMemoryChannelStore chat;
  late bool chatExists;

  ({
    Host host,
    SubagentsPlugin plugin,
    ToolsPlugin tools,
    List<ScriptedProvider> providers,
    Directory dir,
  }) harness({
    required List<List<StreamEvent>> scripts,

    /// One entry per launched child: its WHOLE turn queue (a host builds
    /// its provider once, so a child with several turns needs them all
    /// in one queue).
    List<List<List<StreamEvent>>> childScripts = const [],
  }) {
    final dir = workspace().dir;
    final providers = <ScriptedProvider>[];
    var ci = 0;
    List<List<StreamEvent>> nextChild() =>
        ci < childScripts.length ? childScripts[ci++] : const [];

    final tools = ToolsPlugin(
      workspaceRoot: dir.path,
      tinaDir: Directory('${dir.path}/.tina'),
      mode: PermissionMode.approve,
      osSandbox: false,
    );
    final host = Host.start(HostConfig(
      providerFactory: (model) {
        final p = ScriptedProvider(scripts);
        providers.add(p);
        return p;
      },
      workingDirectory: dir.path,
      plugins: [tools],
      sessionTitle: 'swarm-test',
    ));
    final plugin = SubagentsPlugin(
      parent: host.context,
      // The swarm gate — the same shape plugin_catalog wires (the chat
      // file's existence at spawn time).
      channelExists: (_) => chatExists,
      sessionFactory: standardChildFactory(
        parentTools: tools,
        providerFactory: (model) {
          final p = ScriptedProvider(nextChild());
          providers.add(p);
          return p;
        },
        // Sub-agent mode (the default): NO channel plugin.
        childPlugins: (plugin) => const [],
        // Swarm mode: the channel plugin joining the child to the
        // PARENT's chat as role `subagent`.
        channelChildPlugins: (plugin) => [
          ChannelPlugin(
            openStore: (_) => chat,
            chatExists: (_) => chatExists,
            chatSessionId: plugin.parent.id,
            role: 'subagent',
            humanName: 'sam',
          ),
        ],
      ),
    );
    plugin.mountOn(host.session.loop);
    host.session.loop.addPlugin(plugin);
    return (
      host: host,
      plugin: plugin,
      tools: tools,
      providers: providers,
      dir: dir,
    );
  }

  setUp(() {
    chat = InMemoryChannelStore();
    chatExists = false;
  });

  test('channel: true without a started chat is refused, nothing spawns',
      () {
    final h = harness(scripts: [
      scriptedReply('parent done'),
    ]);
    addTearDown(() async {
      await h.host.whenIdle();
      h.host.close();
      h.dir.deleteSync(recursive: true);
    });

    final result = h.plugin.launch('coordinate the checks', channel: true);
    expect(result.isError, isTrue);
    expect(result.content, contains('channel_start'));
    expect(result.content, contains('started group chat'));
    expect(h.plugin.launchedChildIds, isEmpty);
    // Membership level: nothing was created, nobody joined anything.
    expect(chat.members('#lobby'), isEmpty);
    expect(chat.read('#lobby'), isEmpty);
  });

  test('the default is sub-agent mode: no channel anything, ever', () async {
    final h = harness(scripts: [
      scriptedReply('', calls: [
        ToolUseBlock(
            id: 'c1',
            name: 'launch_subagent',
            input: {'prompt': 'survey quietly'}),
      ]),
    ], childScripts: [
      // The child tries to sneak a channel post, then finishes:
      // without an executor the call fails and nothing reaches any
      // room.
      [
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 's1',
              name: 'channel_say',
              input: {'channel': '#lobby', 'text': 'sneaking in'}),
        ]),
        scriptedReply('done independently'),
      ],
    ]);
    addTearDown(() async {
      await h.host.whenIdle();
      h.host.close();
      h.dir.deleteSync(recursive: true);
    });
    chatExists = true; // a chat exists — the child still stays out

    final outcome = await h.host.send('launch one');
    expect(outcome.stopReason, StopReason.complete);
    await h.host.whenIdle();
    final id = h.plugin.launchedChildIds.single;
    final settled = await h.plugin.inspect(id, action: 'wait');
    expect(settled.content, contains('done independently'));

    // The child's model request: no channel tools, no channel prompt
    // section — no watcher, no etiquette, no deliveries possible.
    final childProvider = h.providers[1];
    final request = childProvider.requests.first;
    expect(
        request.tools.map((t) => t.name).where((n) => n.startsWith('channel_')),
        isEmpty);
    expect(request.systemPrompt, isNot(contains('group-channel')));
    // The failed sneak: the follow-up request carries an error result
    // for the call, and no message row ever landed.
    expect(childProvider.requests.length, greaterThan(1));
    final toolResults = childProvider.requests[1].messages
        .expand((m) => m.content)
        .whereType<ToolResultBlock>()
        .map((b) => b.content)
        .join('\n');
    expect(toolResults, contains('channel_say'));
    // Membership level: the independent child is a member of nothing.
    expect(chat.members('#lobby'), isEmpty);
    expect(
        chat.read('#lobby').where((m) => m.type == ChannelMessageType.message),
        isEmpty);
  });

  test('a participant joins as a member, gets the tools and the etiquette',
      () async {
    final h = harness(scripts: [
      scriptedReply('', calls: [
        ToolUseBlock(
            id: 'c1',
            name: 'launch_subagent',
            input: {
              'prompt': 'coordinate in the room',
              'channel': true,
            }),
      ]),
    ], childScripts: [
      [
        scriptedReply('', calls: [
          ToolUseBlock(
              id: 's1',
              name: 'channel_say',
              input: {'channel': '#lobby', 'text': 'finding: all green'}),
        ]),
        scriptedReply('posted and done'),
      ],
    ]);
    addTearDown(() async {
      await h.host.whenIdle();
      h.host.close();
      h.dir.deleteSync(recursive: true);
    });
    chatExists = true;
    // The session's chat already holds its main agent (a started chat).
    chat.setMember('#lobby', 'calm-heron', status: 'working', role: 'main');

    final outcome = await h.host.send('launch a participant');
    expect(outcome.stopReason, StopReason.complete);
    await h.host.whenIdle();
    final id = h.plugin.launchedChildIds.single;
    final settled = await h.plugin.inspect(id, action: 'wait');
    expect(settled.content, contains('posted and done'));

    // Membership level: the child joined the room as a subagent with
    // its own shortcode identity.
    final members = chat.members('#lobby');
    final sub = members.singleWhere((m) => m.role == 'subagent');
    expect(sub.name, isNot('calm-heron'));
    expect(sub.status, 'working');

    // The child's model request carried the channel tools and the
    // etiquette section, and its post landed attributed to its member
    // identity.
    final request = h.providers[1].requests.first;
    expect(request.tools.map((t) => t.name),
        containsAll(['channel_say', 'channel_read', 'channel_status']));
    expect(request.systemPrompt, contains('<group-channel>'));
    final posted = chat
        .read('#lobby')
        .where((m) => m.type == ChannelMessageType.message)
        .single;
    expect(posted.text, 'finding: all green');
    expect(posted.sender, sub.name);
  });

  test('the launch tool: the channel flag is validated and forwarded',
      () async {
    final h = harness(scripts: const []);
    addTearDown(() async {
      await h.host.whenIdle();
      h.host.close();
      h.dir.deleteSync(recursive: true);
    });
    final tool = LaunchSubagentTool(h.plugin);

    // The schema teaches the two modes.
    expect(tool.schema.inputSchema['properties'], contains('channel'));
    expect(
        (tool.schema.inputSchema['properties']['channel']
            as Map<String, Object?>)['type'],
        'boolean');

    final bad = await tool.execute({'prompt': 'work', 'channel': 'yes'});
    expect(bad.isError, isTrue);
    expect(bad.content, contains('boolean'));

    // Forwarded: a true flag against a chatless session refuses.
    chatExists = false;
    final refused = await tool.execute({
      'prompt': 'work',
      'channel': true,
    });
    expect(refused.isError, isTrue);
    expect(refused.content, contains('channel_start'));
    expect(h.plugin.launchedChildIds, isEmpty);
  });
}
