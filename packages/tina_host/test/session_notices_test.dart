import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

Host start({SessionNotices? notices}) => Host.start(HostConfig(
    workingDirectory: '.',
    notices: notices,
    providerFactory: (_) => ScriptedProvider([])));

final class _Restored extends AgentPlugin {
  @override
  String get id => 'test/restored';
  @override
  SessionSeed openSession(PluginSession session) => SessionSeed(
      log: [const ContextClearedEntry(seq: 0)], details: SessionDetails());
}

void main() {
  test('startup notices follow restored history and do not survive a restart',
      () async {
    final notices = SessionNotices()..write('startup');
    Host resume(SessionNotices writer) => Host.resume(
        HostConfig(
            workingDirectory: '.',
            notices: writer,
            plugins: [_Restored()],
            providerFactory: (_) => ScriptedProvider([])),
        'saved');
    final host = resume(notices);
    final connection = host.connect();
    addTearDown(connection.close);
    addTearDown(host.shutdown);
    final snapshot = connection.attach().initial;
    expect(snapshot.throughSeq, 0);
    expect(
        connection.notices(snapshot: snapshot).entries.single.afterHistorySeq,
        0);
    await host.shutdown();
    final restarted = resume(SessionNotices());
    addTearDown(restarted.shutdown);
    final next = restarted.connect();
    addTearDown(next.close);
    final fresh = next.attach().initial;
    expect(fresh.cursor.epoch, isNot(snapshot.cursor.epoch));
    expect(next.notices(snapshot: fresh).entries, isEmpty);
  });

  test(
      'notices follow history, remain out of the log and use fixed page bounds',
      () async {
    final host = start();
    addTearDown(host.shutdown);
    final connection = host.connect(role: SessionRole.observer);
    addTearDown(connection.close);
    host.notices.write('before');
    host.session.loop.recordUsage(const UsageRecordedEntry(turnId: 't'));
    host.notices.write('after');
    final attachment = connection.attach();
    final snapshot = attachment.initial;
    host.notices.write('later');
    final first = attachment.notices(snapshot: snapshot, limit: 1);
    expect(first.entries.single.text, 'before');
    expect(first.entries.single.afterHistorySeq, -1);
    expect(first.hasMore, isTrue);
    final second =
        attachment.notices(snapshot: snapshot, afterSeq: first.nextAfterSeq);
    expect(second.entries.single.text, 'after');
    expect(second.entries.single.afterHistorySeq, snapshot.throughSeq);
    expect(second.hasMore, isFalse);
    expect(() => second.entries.clear(), throwsUnsupportedError);
    expect(host.session.loop.log, hasLength(1));
    expect(host.session.loop.log.single, isA<UsageRecordedEntry>());
    expect(() => connection.notices(snapshot: snapshot, afterSeq: 999),
        throwsRangeError);
    expect(() => connection.notices(snapshot: snapshot, limit: 0),
        throwsRangeError);
    final other = start();
    addTearDown(other.shutdown);
    expect(
        () => other.connect().notices(snapshot: snapshot), throwsArgumentError);
  });

  test(
      'slow and detached consumers recover bounded output with explicit expiry',
      () async {
    final host = start(
        notices: SessionNotices(
            maxEntries: 3, maxCharacters: 12, maxNoticeCharacters: 8));
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    final slow = connection.attach();
    host.notices.write('old');
    await Future<void>.delayed(Duration.zero);
    final old = connection.attach().initial;
    for (var i = 0; i < 100; i++) {
      host.notices.write('$i');
      await Future<void>.delayed(Duration.zero);
    }
    expect(slow.bufferedUpdates, 1);
    final update = (await slow.next())!;
    expect(update.coalesced, isTrue);
    final page = slow.notices(snapshot: update.snapshot);
    expect(page.entries.map((e) => e.text), ['97', '98', '99']);
    expect(page.omittedThroughSeq, 97);
    expect(page.omittedAfterHistorySeq, -1);
    final expired = connection.notices(snapshot: old);
    expect(expired.entries, isEmpty);
    expect(expired.omittedThroughSeq, old.throughNoticeSeq);
    expect(expired.hasMore, isFalse);
    slow.close();
    host.notices.write('abcdefghijk');
    final reconnect = connection.attach();
    final latest = reconnect.notices(snapshot: reconnect.initial);
    expect(latest.entries.last.text, 'abcdefgh');
    expect(latest.entries.last.truncated, isTrue);
    expect(latest.entries.fold<int>(0, (n, e) => n + e.text.length),
        lessThanOrEqualTo(12));
    await host.shutdown();
    host.notices.write('after shutdown');
    expect(
        host.notices.retained.any((e) => e.text == 'after shutdown'), isFalse);
  });

  test('notices written during publication wait for that history to commit',
      () {
    final host = start();
    addTearDown(host.shutdown);
    final connection = host.connect();
    addTearDown(connection.close);
    final handle = host.session.loop.subscribe((entry, event) {
      if (event == LogEvent.appended) host.notices.write('published');
    });
    host.session.loop.recordUsage(const UsageRecordedEntry(turnId: 'good'));
    final good = connection.attach().initial;
    expect(connection.notices(snapshot: good).entries.single.afterHistorySeq,
        good.throughSeq);
    final failing = host.session.loop.subscribe((entry, event) {
      if (event == LogEvent.appended) throw StateError('disk failed');
    });
    expect(
        () => host.session.loop
            .recordUsage(const UsageRecordedEntry(turnId: 'bad')),
        throwsA(anything));
    host.notices.write('must stay hidden');
    final failed = connection.attach().initial;
    expect(failed.historyPublicationFailed, isTrue);
    expect(failed.throughNoticeSeq, good.throughNoticeSeq);
    expect(connection.notices(snapshot: failed).entries, hasLength(1));
    host.session.loop.unsubscribe(handle);
    host.session.loop.unsubscribe(failing);
  });
}
