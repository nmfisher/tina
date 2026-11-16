import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina_channel_test');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // WAL sidecars can linger briefly on some platforms; not a failure.
    }
  });

  // Both implementations must satisfy the same contract: this is the
  // seam, exercised on both sides.
  List<(String, ChannelStoreApi Function())> stores() => [
        ('in-memory', InMemoryChannelStore.new),
        ('sqlite', () => SqliteChannelStore.open('${dir.path}/channel.db')),
      ];

  for (final (name, open) in stores()) {
    group('$name store', () {
      late ChannelStoreApi store;
      setUp(() => store = open());
      tearDown(() => store.close());

      test('#lobby exists from the first open', () {
        expect(store.listChannels().map((c) => c.name), contains('#lobby'));
      });

      test('ensureChannel is idempotent and normalizes', () {
        store.ensureChannel('Lobby');
        store.ensureChannel('#lobby ');
        final names = store.listChannels().map((c) => c.name).toList();
        expect(names.where((n) => n == '#lobby').length, 1);
      });

      test('post round-trips sender, text and default type', () {
        final posted = store.post('#lobby',
            sender: 'tina-main', text: 'first message');
        expect(posted.id, greaterThan(0));
        expect(posted.sender, 'tina-main');
        expect(posted.text, 'first message');
        expect(posted.type, ChannelMessageType.message);
        final read = store.read('#lobby');
        expect(read.length, 1);
        expect(read.single.sender, 'tina-main');
        expect(read.single.text, 'first message');
      });

      test('posting to a fresh channel creates it', () {
        store.post('#perm-boxes', sender: 'agent', text: 'hello');
        expect(store.listChannels().map((c) => c.name), contains('#perm-boxes'));
      });

      test('mentions and reply_to round-trip', () {
        final first = store.post('#lobby', sender: 'a', text: 'q');
        final reply = store.post('#lobby',
            sender: 'b',
            text: 'cc @tina-main',
            mentions: parseMentions('cc @tina-main'),
            replyTo: first.id);
        final read = store.read('#lobby');
        expect(read.last.mentions, ['tina-main']);
        expect(read.last.replyTo, first.id);
        expect(read.first.mentions, isEmpty);
        expect(reply.mentions, ['tina-main']);
      });

      test('read(sinceId) returns strictly newer messages, oldest first',
          () {
        final a = store.post('#lobby', sender: 'a', text: '1');
        store.post('#lobby', sender: 'a', text: '2');
        store.post('#lobby', sender: 'a', text: '3');
        final tail = store.read('#lobby', sinceId: a.id);
        expect(tail.map((m) => m.text), ['2', '3']);
      });

      test('read(sinceTime) returns strictly newer messages', () async {
        final a = store.post('#lobby', sender: 'a', text: '1');
        await Future<void>.delayed(const Duration(milliseconds: 2));
        store.post('#lobby', sender: 'a', text: '2');
        final tail = store.read('#lobby', sinceTime: a.createdAt);
        expect(tail.map((m) => m.text), ['2']);
      });

      test('read(limit) keeps the most recent window', () {
        for (var i = 1; i <= 5; i++) {
          store.post('#lobby', sender: 'a', text: '$i');
        }
        expect(store.read('#lobby', limit: 3).map((m) => m.text),
            ['3', '4', '5']);
        expect(store.read('#lobby', limit: 100).length, 5);
      });

      test('setMember announces a status message and upserts', () {
        store.setMember('#lobby', 'tina-main',
            status: 'working', role: 'agent', summary: 'channel store');
        final members = store.members('#lobby');
        expect(members.length, 1);
        expect(members.single.name, 'tina-main');
        expect(members.single.role, 'agent');
        expect(members.single.status, 'working');
        expect(members.single.summary, 'channel store');
        final status = store.read('#lobby').last;
        expect(status.type, ChannelMessageType.status);
        expect(status.sender, 'tina-main');
        expect(status.text, contains('working'));

        store.setMember('#lobby', 'tina-main', status: 'done');
        expect(store.members('#lobby').length, 1);
        expect(store.members('#lobby').single.status, 'done');
        expect(store.read('#lobby').where((m) => m.type == ChannelMessageType.status).length, 2);
      });

      test('setMember(announce: false) writes only the member row', () {
        store.setMember('#lobby', 'quiet', status: 'idle', announce: false);
        expect(store.members('#lobby').single.name, 'quiet');
        expect(store.read('#lobby'), isEmpty);
      });

      test('lastMessageId tracks the channel cursor', () {
        expect(store.lastMessageId('#lobby'), 0);
        final a = store.post('#lobby', sender: 'a', text: '1');
        expect(store.lastMessageId('#lobby'), a.id);
        store.post('#other', sender: 'a', text: '2');
        expect(store.lastMessageId('#lobby'), a.id);
      });

      test('channels list counts messages and members', () {
        store.post('#lobby', sender: 'a', text: '1');
        store.setMember('#lobby', 'a', status: 'working');
        final lobby =
            store.listChannels().singleWhere((c) => c.name == '#lobby');
        expect(lobby.messages, 2); // message + status announce
        expect(lobby.members, 1);
        expect(lobby.lastMessageAt, isNotNull);
      });

      test('invalid input is rejected', () {
        expect(() => store.post(' ', sender: 'a', text: 'x'),
            throwsFormatException);
        expect(() => store.post('#lobby', sender: ' ', text: 'x'),
            throwsFormatException);
        expect(() => store.read('#lobby', limit: 0), throwsFormatException);
      });
    });
  }

  group('sqlite persistence', () {
    test('data survives close and reopen', () {
      final path = '${dir.path}/reopen.db';
      final first = SqliteChannelStore.open(path);
      first.post('#lobby', sender: 'tina-main', text: 'durable');
      first.setMember('#lobby', 'tina-main', status: 'working');
      first.close();
      final second = SqliteChannelStore.open(path);
      expect(second.read('#lobby').map((m) => m.text),
          containsAll(['working', 'durable']));
      expect(second.members('#lobby').single.status, 'working');
      second.close();
    });

    test('a newer schema version is refused', () {
      final path = '${dir.path}/future.db';
      SqliteChannelStore.open(path).close();
      final raw = sqlite3.sqlite3.open(path);
      raw.execute('PRAGMA busy_timeout=5000');
      raw.userVersion = SqliteChannelStore.schemaVersion + 1;
      raw.close();
      expect(() => SqliteChannelStore.open(path),
          throwsA(isA<ChannelStoreException>()));
    });
  });
}
