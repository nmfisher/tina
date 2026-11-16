import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';

/// Session scoping: a group chat belongs to one session — one store
/// file per session id under `.tina/channels/`. Two sessions in one
/// workspace never see each other; the same id reattaches to its own
/// history (resume). The sqlite file layout, against real files.
void main() {
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('tina_channel_scope');
  });

  tearDown(() {
    try {
      workspace.deleteSync(recursive: true);
    } on FileSystemException {
      // WAL sidecars can linger briefly; not a failure.
    }
  });

  /// Typed wrapper: a bare conditional-export call at statement level
  /// lets flow analysis pick the unsupported Never variant.
  ChannelStoreApi openChat(String sessionId) =>
      openDefaultChannelStore(workspace.path, sessionId);

  test('two sessions in one workspace never see each other', () {
    final a = openChat('session-a');
    final b = openChat('session-b');
    addTearDown(a.close);
    addTearDown(b.close);

    // One file per session chat, siblings under .tina/channels/.
    expect(a.file,
        p.join(workspace.path, '.tina', 'channels', 'session-a.db'));
    expect(a.file, isNot(b.file));

    a.post('#lobby', sender: 'agent-a', text: 'only in session a');
    a.setMember('#lobby', 'agent-a', status: 'working', role: 'main');
    a.post('#side', sender: 'agent-a', text: 'a private channel');

    // Session b's chat is a different database: no channels, messages
    // or members leaked from a — isolation by construction.
    expect(b.read('#lobby'), isEmpty);
    expect(b.members('#lobby'), isEmpty);
    final names = b.listChannels().map((c) => c.name).toList();
    expect(names, ['#lobby']); // its own empty room, nothing else
    expect(b.listChannels().first.messages, 0);
  });

  test('resume: same session id, new store connection — full history',
      () {
    final first = openChat('resume-me');
    first.post('#lobby', sender: 'agent', text: 'before the process exited');
    first.setMember('#lobby', 'agent', status: 'working', role: 'main');
    final cursor = first.lastMessageId('#lobby');
    expect(cursor, greaterThan(0));
    first.close();

    // A resumed session reopens the same chat file: scrollback,
    // presence and the read cursor all survive the process.
    final second = openChat('resume-me');
    addTearDown(second.close);
    final history = second.read('#lobby');
    expect(history.first.text, 'before the process exited');
    expect(second.lastMessageId('#lobby'), cursor);
    expect(second.members('#lobby').single.name, 'agent');
    expect(second.members('#lobby').single.role, 'main');

    // And the chat keeps appending on the same id sequence.
    second.post('#lobby', sender: 'agent', text: 'resumed');
    expect(second.read('#lobby').length, history.length + 1);
  });

  test('exotic session ids map onto safe chat file names', () {
    final path = defaultChannelStorePath(workspace.path, 'weird/id ⑊');
    expect(p.basename(path), 'weird-id--.db');
    expect(p.dirname(path),
        p.join(workspace.path, '.tina', 'channels'));
    expect(defaultChannelStorePath(workspace.path, '+++').isNotEmpty, isTrue);
  });
}
