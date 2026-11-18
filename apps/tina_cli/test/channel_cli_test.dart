import 'dart:io';

import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:tina_channel/tina_channel_sqlite.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina/tina.dart' show runCli;

/// The `tina channel` subcommand surface, exercised through [runCli]
/// against a temp workspace. A chat belongs to a session: the commands
/// default to the workspace's current (most recently active) session,
/// `--session ID` inspects another session's chat read-only, and
/// `--db` points at a store file directly (scripting). Output is
/// verified through the store, the way cli_test verifies imports.
void main() {
  late Directory workspace;
  late String sessionsPath;
  late String latestDb;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('tina_channel_cli');
    sessionsPath = '${workspace.path}/.tina/sessions.db';
    // Seed the workspace's session store: an older session, then the
    // current one (created last — highest activity key, so latest).
    Directory('${workspace.path}/.tina').createSync(recursive: true);
    final sessions = SessionStore.open(sessionsPath);
    sessions.createSession('s-old', title: 'older');
    sessions.createSession('s-now', title: 'current');
    sessions.close();
    latestDb = '${workspace.path}/.tina/channels/s-now.db';
  });

  tearDown(() {
    try {
      workspace.deleteSync(recursive: true);
    } on FileSystemException {
      // WAL sidecars can linger briefly; not a failure.
    }
  });

  Future<int> channel(List<String> args) =>
      runCli(['channel', ...args, '--cwd', workspace.path]);

  test('routing: bare channel prints help, unknown subcommands fail',
      () async {
    expect(await runCli(['channel']), 0);
    expect(await channel(['nope']), 64);
    expect(await runCli(['--unknown']), 64); // routing leaves flags alone
  });

  test('say posts to the CURRENT session chat with parsed mentions',
      () async {
    expect(await channel(['say', '#lobby', 'hey @subagent look']), 0);
    final store = SqliteChannelStore.open(latestDb);
    addTearDown(store.close);
    final messages = store.read('#lobby');
    expect(messages.length, 1);
    expect(messages.single.sender, 'user');
    expect(messages.single.mentions, ['subagent']);
    expect(await channel(['say', '#lobby', '']), 64);
  });

  test('read and list succeed after activity', () async {
    expect(await channel(['say', '#design', 'first', 'words']), 0);
    expect(await channel(['read', '#design']), 0);
    expect(await channel(['read', '#design', '--limit', '5']), 0);
    final store = SqliteChannelStore.open(latestDb);
    addTearDown(store.close);
    final first = store.read('#design').first;
    expect(first.text, 'first words'); // positional TEXT... joined
    expect(await channel(['read', '#design', '--since', '${first.id}']), 0);
    expect(await channel(['read', '#design', '--since', 'garbage']), 64);
    expect(await channel(['list']), 0);
  });

  test('status sets and lists presence', () async {
    expect(
        await channel([
          'status',
          '#lobby',
          '--as',
          'user',
          '--set',
          'working',
          '--summary',
          'reviewing'
        ]),
        0);
    expect(await channel(['status']), 0);
    expect(await channel(['status', '#lobby']), 0);
    final store = SqliteChannelStore.open(latestDb);
    addTearDown(store.close);
    final member = store.members('#lobby').single;
    expect(member.name, 'user');
    expect(member.role, 'user');
    expect(member.status, 'working');
    expect(member.summary, 'reviewing');
    final announced = store.read('#lobby').last;
    expect(announced.type, ChannelMessageType.status);
    expect(await channel(['status', '#lobby', '--set', 'vibing']), 64);
  });

  test('--session inspects another session\'s chat, read-only', () async {
    // Write into the older session's chat through --db (scripting
    // escape hatch), then verify the scoped surface around it.
    final oldDb = '${workspace.path}/.tina/channels/s-old.db';
    expect(
        await channel(
            ['say', '#old-room', 'history', '--db', oldDb, '--as', 'recap']),
        0);

    // Reading another session's chat works...
    expect(await channel(['read', '#old-room', '--session', 's-old']), 0);
    expect(await channel(['list', '--session', 's-old']), 0);
    expect(await channel(['status', '#old-room', '--session', 's-old']), 0);

    // ...but writing it does not: another session's chat is read-only.
    expect(
        await channel(
            ['say', '#old-room', 'nope', '--session', 's-old']),
        64);
    expect(
        await channel([
          'status',
          '#old-room',
          '--session',
          's-old',
          '--set',
          'working'
        ]),
        64);
    final store = SqliteChannelStore.open(oldDb);
    addTearDown(store.close);
    expect(store.read('#old-room').length, 1); // only the --db write

    // An unknown id is refused outright.
    expect(await channel(['list', '--session', 'ghost']), 64);
  });

  test('sessions isolate: the current chat does not see the old one',
      () async {
    final oldDb = '${workspace.path}/.tina/channels/s-old.db';
    expect(
        await channel(
            ['say', '#lobby', 'older session message', '--db', oldDb]),
        0);
    expect(await channel(['say', '#lobby', 'current message']), 0);

    final now = SqliteChannelStore.open(latestDb);
    addTearDown(now.close);
    final messages = now.read('#lobby');
    expect(messages.map((m) => m.text), ['current message']);
  });

  test('without a session store the command explains itself', () async {
    final empty = Directory.systemTemp.createTempSync('tina_channel_none');
    addTearDown(() => empty.deleteSync(recursive: true));
    expect(
        await runCli(
            ['channel', 'list', '--cwd', empty.path]),
        64);
  });

  test('the session chat database lives under .tina/channels', () async {
    expect(await channel(['list']), 0);
    expect(File(latestDb).existsSync(), isTrue);
  });

/// Phase 4: the human's CLI compact path — digest + kept tail in the
/// view, rows retained in the database, --clear wipes the view.
/// Verified through the store, the way this file's other tests do.
group('compact', () {


  test('compact keeps recent messages and writes a digest', () async {
    for (var i = 1; i <= 30; i++) {
      await channel(['say', '#work', 'message $i', '--as', 'nick']);
    }
    expect(await channel(['compact', '#work', '--keep', '10']), 0);

    final store = SqliteChannelStore.open(latestDb);
    addTearDown(store.close);
    final view = store.read('#work', limit: 100);
    // digest + 10 kept: the view shrank...
    expect(view.length, 11);
    expect(view.last.type, ChannelMessageType.system);
    expect(view.last.text, contains('superseded 20 messages'));
    expect(view.any((m) => m.text == 'message 30'), isTrue);
    expect(view.any((m) => m.text == 'message 5'), isFalse);
    // ...while the database kept every row.
    final raw = sqlite3.sqlite3.open(latestDb);
    addTearDown(raw.close);
    final rows = raw
        .select(
            'SELECT COUNT(*) AS n FROM messages WHERE channel = ?', ['#work'])
        .single['n'] as int;
    expect(rows, 31); // 30 messages + digest; nothing deleted
  });

  test('clear gives a fresh view and keeps identity', () async {
    await channel(['say', '#lobby', 'hello', '--as', 'nick']);
    expect(await channel(['compact', '#lobby', '--clear']), 0);
    final store = SqliteChannelStore.open(latestDb);
    addTearDown(store.close);
    expect(store.read('#lobby', limit: 10), isEmpty);
    await channel(['say', '#lobby', 'again', '--as', 'nick']);
    expect(store.read('#lobby').single.text, 'again');
  });
  });
}
