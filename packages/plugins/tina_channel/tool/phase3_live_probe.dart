// Live check (phase 3): two sessions sharing one workspace channel
// database. The human posts a mention from outside; session B
// turn boundary (plugin.onPrompt) delivers it. Transcript follows.
import 'dart:io';

import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

TurnContext turn() => TurnContext(
      CancelToken(),
      input: const Input('live', id: 'i'),
      messages: const [],
      promptSections: [],
      pinnedTools: const [],
    );

PluginSession session(String id) => PluginSession(
      id: id,
      workingDirectory: '.',
      notifyChanged: () {},
    );

void main() {
  final workspace =
      Directory.systemTemp.createTempSync('tina-phase3-live-');
  Directory('${workspace.path}/.tina/channels').createSync(recursive: true);
  final open = (String scope) => SqliteChannelStore.open(
      defaultChannelStorePath(workspace.path, scope));

  // One session's chat: the main agent and a subagent child both open
  // the SAME scope (the session id); the child passes chatSessionId.
  final a = ChannelPlugin(
      openStore: open, agentName: 'amber-lynx', role: 'main',
      humanName: 'nick');
  a.openSession(session('shared'));

  final b = ChannelPlugin(
      openStore: open, agentName: 'bold-moth', role: 'subagent',
      humanName: 'nick', chatSessionId: 'shared');
  b.openSession(session('child-of-shared'));

  print('members of #lobby: '
      '${a.storeForUi!.members('#lobby').map((m) => '${m.name}/${m.role}').join(', ')}');

  // The human (outside both sessions, like the CLI/TUI pane) posts a
  // mention addressed to B.
  a.storeForUi!.post('#lobby',
      sender: 'nick', text: '@bold-moth please sanity-check the index');

  // B next turn boundary:
  final ctx = turn();
  b.onPrompt(ctx);
  print('--- B turn sections:');
  for (final section in ctx.promptSections) {
    print(section);
  }
  print('--- delivered: '
      '${ctx.promptSections.join('\n').contains('sanity-check')}');

  // And the next turn carries nothing (cursor marked):
  final next = turn();
  b.onPrompt(next);
  print('--- redelivered on next turn (want false): '
      '${next.promptSections.join('\n').contains('sanity-check')}');

  // Unmentioned chatter stays pull-only:
  a.storeForUi!.post('#lobby', sender: 'amber-lynx', text: 'thinking aloud');
  final quiet = turn();
  b.onPrompt(quiet);
  print('--- chatter delivered (want false): '
      '${quiet.promptSections.join('\n').contains('thinking aloud')}');

  a.closeSession();
  b.closeSession();
  workspace.deleteSync(recursive: true);
}
