import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';
import 'package:tina/tina.dart' show runCli;

/// The `tina channel` subcommand surface, exercised through [runCli]
/// against a temp workspace: the Phase 1 acceptance path (a human
/// reads and posts from a terminal). Output is verified through the
/// store, the way cli_test verifies imports.
void main() {
  late Directory workspace;
  late String dbPath;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('tina_channel_cli');
    dbPath = '${workspace.path}/.tina/channel.db';
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

  test('say posts as the named sender with parsed mentions', () async {
    expect(await channel(['say', '#lobby', 'hey @subagent look']), 0);
    final store = SqliteChannelStore.open(dbPath);
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
    final store = SqliteChannelStore.open(dbPath);
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
    final store = SqliteChannelStore.open(dbPath);
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

  test('the workspace database lives under .tina', () async {
    expect(await channel(['list']), 0);
    expect(File(dbPath).existsSync(), isTrue);
  });
}
