/// The channel store's v1→v2 in-place migration (the hotfix for the
/// resume crash): a real v1 file — written by a pre-compaction build —
/// opens, migrates inside the open transaction, and every existing
/// row survives. Garbage is refused without destruction; a future
/// schema is still refused.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// Builds a v1 chat file exactly as the pre-compaction code wrote it,
/// with real rows in all three tables.
String buildV1File(Directory dir) {
  final path = '${dir.path}/v1.db';
  final db = sqlite3.open(path);
  db.execute('CREATE TABLE channels ('
      'name TEXT PRIMARY KEY, '
      'created_at TEXT NOT NULL)');
  db.execute('CREATE TABLE messages ('
      'id INTEGER PRIMARY KEY, '
      'channel TEXT NOT NULL REFERENCES channels(name), '
      'sender TEXT NOT NULL, '
      'text TEXT NOT NULL, '
      'type TEXT NOT NULL, '
      'mentions TEXT, '
      'reply_to INTEGER REFERENCES messages(id), '
      'created_at TEXT NOT NULL)');
  db.execute(
      'CREATE INDEX messages_channel_id ON messages(channel, id)');
  db.execute('CREATE TABLE members ('
      'channel TEXT NOT NULL REFERENCES channels(name), '
      'name TEXT NOT NULL, '
      'role TEXT NOT NULL, '
      'status TEXT NOT NULL, '
      'summary TEXT, '
      'last_seen TEXT NOT NULL, '
      'PRIMARY KEY (channel, name))');
  db.execute("INSERT INTO channels (name, created_at) VALUES "
      "('#lobby', '2026-01-01T00:00:00Z'), "
      "('#war', '2026-01-01T00:01:00Z')");
  db.execute("INSERT INTO messages (channel, sender, text, type, "
      "created_at) VALUES ('#lobby', 'calm-heron', 'finding one', "
      "'message', '2026-01-01T00:02:00Z'), "
      "('#lobby', 'calm-heron', 'working — checks', 'status', "
      "'2026-01-01T00:03:00Z'), "
      "('#war', 'bold-moth', 'war room note', 'message', "
      "'2026-01-01T00:04:00Z')");
  db.execute("INSERT INTO members (channel, name, role, status, "
      "last_seen) VALUES ('#lobby', 'calm-heron', 'main', 'working', "
      "'2026-01-01T00:03:00Z'), ('#lobby', 'sam', 'human', 'joined', "
      "'2026-01-01T00:03:30Z')");
  db.userVersion = 1;
  db.close();
  return path;
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina-channel-v1-');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a v1 file migrates in place with every row surviving', () {
    final path = buildV1File(dir);
    final store = SqliteChannelStore.open(path);
    addTearDown(store.close);

    // Stamped to the current schema.
    final raw = sqlite3.open(path);
    addTearDown(raw.close);
    expect(raw.userVersion, SqliteChannelStore.schemaVersion);
    expect(
        raw.select('PRAGMA table_info(channels)')
            .map((r) => r['name'])
            .toList(),
        contains('compaction_id'));
    // The audit trail is whole: every pre-migration row is still there.
    expect(raw.select('SELECT COUNT(*) c FROM messages').single['c'], 3);
    expect(raw.select('SELECT COUNT(*) c FROM members').single['c'], 2);

    // The store reads the migrated rows through the normal interface.
    final lobby = store.read('#lobby');
    expect(lobby.map((m) => m.text), contains('finding one'));
    final members = store.members('#lobby');
    expect(members.map((m) => m.name), containsAll(['calm-heron', 'sam']));

    // Compaction (the v2 feature) works on migrated data, and the
    // migrated channels started with no compaction point.
    final compaction =
        store.compact('#lobby', actor: 'calm-heron', keep: 1);
    expect(compaction.digested, greaterThanOrEqualTo(1));
    expect(store.read('#lobby').last.text, contains('superseded'));
    // The other channel's view is untouched.
    expect(store.read('#war').single.text, 'war room note');
  });

  test('a current-version file is untouched by the migration step', () {
    final path = buildV1File(dir);
    // Bring it to current with a real open, then reopen: no step runs,
    // the data is stable.
    SqliteChannelStore.open(path).close();
    final before = File(path).lengthSync();
    final store = SqliteChannelStore.open(path);
    addTearDown(store.close);
    expect(store.read('#lobby').map((m) => m.text), contains('finding one'));
    expect(File(path).lengthSync(), greaterThanOrEqualTo(before));
  });

  test('a garbage file is refused without destruction', () {
    final path = '${dir.path}/garbage.db';
    File(path).writeAsStringSync('this is not a database at all\n');
    final bytesBefore = File(path).readAsBytesSync();
    expect(() => SqliteChannelStore.open(path),
        throwsA(isA<ChannelStoreException>()));
    expect(File(path).readAsBytesSync(), bytesBefore,
        reason: 'a refused open must never rewrite the file');
  });

  test('a future schema is still refused', () {
    final path = buildV1File(dir);
    final raw = sqlite3.open(path);
    raw.userVersion = SqliteChannelStore.schemaVersion + 1;
    raw.close();
    expect(
        () => SqliteChannelStore.open(path),
        throwsA(isA<ChannelStoreException>().having((e) => e.toString(),
            'toString',
            contains('user_version ${SqliteChannelStore.schemaVersion + 1}'))));
  });

  test('the session-level resume path recovers: the plugin opens a v1 chat',
      () {
    // The exact crash from the field: resuming a session whose chat
    // file is v1 must open (migrate), not abort.
    final path = buildV1File(dir);
    final workspace = Directory('${dir.path}/ws')..createSync();
    // Place the v1 file where the session's chat lives.
    final chatPath = defaultChannelStorePath(workspace.path, 's-resume');
    File(chatPath).parent.createSync(recursive: true);
    File(path).copySync(chatPath);
    final plugin = ChannelPlugin(
      openStore: (scope) =>
          SqliteChannelStore.open(defaultChannelStorePath(workspace.path, scope)),
      chatExists: (scope) =>
          File(defaultChannelStorePath(workspace.path, scope)).existsSync(),
      chatSessionId: 's-resume',
      agentName: 'calm-heron',
      role: 'main',
      humanName: 'sam',
    );
    plugin.openSession(PluginSession(
      id: 's-resume-again',
      workingDirectory: workspace.path,
      notifyChanged: () {},
    ));
    addTearDown(plugin.closeSession);
    expect(plugin.isStarted, isTrue, reason: 'the v1 chat reattached');
    expect(plugin.name, 'calm-heron');
  });

  test('a channel store that cannot open degrades instead of aborting',
      () async {
    // The non-fatal startup rule: the open failure is a notice, the
    // session runs chatless, tools refuse — and an approved
    // channel_start retries the open and recovers.
    final lines = <String>[];
    var broken = true;
    final workspace = Directory('${dir.path}/ws2')..createSync();
    final chatPath = defaultChannelStorePath(workspace.path, 's-broken');
    File(chatPath).parent.createSync(recursive: true);
    File(chatPath).writeAsStringSync('not a database\n');

    late ChannelPlugin plugin;
    plugin = ChannelPlugin(
      openStore: (scope) {
        if (broken) {
          throw ChannelStoreException('cannot open channel store $chatPath',
              StateError('file is not a database'));
        }
        return SqliteChannelStore.open(chatPath);
      },
      chatExists: (_) => true,
      agentName: 'calm-heron',
      role: 'main',
      humanName: 'sam',
      approveStart: ({required channel, purpose, required members}) async {
        // The "user approved" — and the store became openable (the
        // operator removed the broken file, say).
        File(chatPath).deleteSync();
        broken = false;
        return true;
      },
      terminal: _NoticeTerminal(lines),
    );
    plugin.openSession(PluginSession(
      id: 's-broken',
      workingDirectory: workspace.path,
      notifyChanged: () {},
    ));
    addTearDown(plugin.closeSession);

    // The session started: dormant tools, a notice, no crash.
    expect(plugin.isStarted, isFalse);
    expect(lines.single, contains('group chat unavailable'));
    final refusal = await plugin.execute(
        'channel_say', {'channel': '#lobby', 'text': 'hi'});
    expect(refusal.isError, isTrue);
    expect(refusal.content, contains('No group chat has been started'));

    // An approved channel_start retries the open and recovers.
    final started = await plugin.execute('channel_start', {});
    expect(started.isError, isFalse, reason: started.content);
    expect(plugin.isStarted, isTrue);
  });
}

final class _NoticeTerminal implements Terminal {
  _NoticeTerminal(this.lines);
  final List<String> lines;
  @override
  void writeln([String? line]) => lines.add(line ?? '');
  @override
  Future<String> ask(String prompt) async => '';
}
