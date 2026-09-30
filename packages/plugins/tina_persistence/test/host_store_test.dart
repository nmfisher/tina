// The persistence plugin owns the store link: opened at start, subscribed to the log
// before the first turn, closed by whoever owns the host. Resume seeds
// the loop from the store's slice; new entries continue the same log.
//
// Run: dart test
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_persistence/tina_persistence.dart';

/// One provider per call, per the config contract: the factory closes
/// over the script queue and pops one script per host built.
HostConfig _config(Directory tmp, List<List<List<StreamEvent>>> scripts,
        {bool persist = true}) =>
    HostConfig(
      providerFactory: (model) {
        expect(model, 'scripted');
        return ScriptedProvider(
            scripts.isEmpty ? const [] : scripts.removeAt(0));
      },
      workingDirectory: tmp.path,
      plugins: [
        if (persist)
          PersistencePlugin(openStore: () => SessionStore.open(dbPath))
      ],
    );

late Directory tmp;
late String dbPath;

void main() {
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tina_host_store_');
    dbPath = '${tmp.path}/sessions.db';
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('without persistence the session stays in memory', () async {
    final host = Host.start(_config(
        tmp,
        [
          [scriptedReply('hi')]
        ],
        persist: false));
    expect(host.config.plugins.whereType<PersistencePlugin>(), isEmpty);
    await host.send('hello');
    expect(host.session.loop.log, isNotEmpty);
    host.close();
  });

  test('start + send persists every entry; store bytes equal loop bytes',
      () async {
    final host = Host.start(
        _config(tmp, [
          [
            scriptedReply('', calls: [
              ToolUseBlock(id: 'c1', name: 'echo', input: {'text': 'x'})
            ]),
            scriptedReply('done'),
          ]
        ]),
        sessionId: 's-1');
    // The loop has no echo executor mounted by the test config's plugins,
    // so the call comes back "no executor" — fine: the log still records
    // the exchange, which is what this test pins.
    await host.send('hello', turnId: 't1');

    final store =
        host.config.plugins.whereType<PersistencePlugin>().single.store;
    expect(
        host.config.plugins.whereType<PersistencePlugin>().single.registryKey,
        isNotNull);
    final sessions = store.list();
    expect([for (final s in sessions) s.id], ['s-1']);
    final fromStore = store.readEntries('s-1');
    expect(jsonEncode([for (final e in fromStore) e.toJson()]),
        jsonEncode([for (final e in host.session.loop.log) e.toJson()]));
    expect(store.checkGaps('s-1'), isEmpty);
    final kinds = [for (final e in fromStore) e.kind];
    expect(kinds.first, 'turn_started');
    expect(kinds.last, 'turn_ended');
    host.close();
  });

  test('resume seeds the loop; the first request carries the history',
      () async {
    // First host: one turn lands in the store.
    final first = Host.start(
        _config(tmp, [
          [scriptedReply('first answer')]
        ]),
        sessionId: 's-old');
    await first.send('first question', turnId: 't1');
    first.close();

    // Second host over the same file: the loop starts with the history.
    final resumed = Host.resume(
        _config(tmp, [
          [scriptedReply('second answer')]
        ]),
        's-old');
    expect(resumed.session.loop.log.length, 5, reason: 'seeded, not empty');
    await resumed.send('second question', turnId: 't2');

    // The request saw old input, old reply, then the new input.
    final provider = resumed.session.loop;
    final view = provider.derive().messages;
    expect(view.length, 4);
    expect((view[0].content.single as TextBlock).text, 'first question');
    expect((view[1].content.single as TextBlock).text, 'first answer');
    expect((view[2].content.single as TextBlock).text, 'second question');

    // The store holds one continuous log: seqs run to the end, no gaps,
    // old entries untouched, new entries appended after them.
    final store =
        resumed.config.plugins.whereType<PersistencePlugin>().single.store;
    expect(store.checkGaps('s-old'), isEmpty);
    final all = store.readEntries('s-old');
    for (var i = 0; i < all.length; i++) {
      expect(all[i].seq, i, reason: 'row $i');
    }
    expect(all.length, 10);
    expect(
      jsonEncode([for (final e in all.take(5)) e.toJson()]),
      jsonEncode([for (final e in (first.session.loop.log)) e.toJson()]),
      reason: 'resuming must not rewrite history',
    );
    resumed.close();
  });

  test('resume of an unknown session fails loudly', () {
    final store = SessionStore.open(dbPath);
    store.close();
    expect(
        () => Host.resume(
            _config(tmp, [
              [scriptedReply('x')]
            ]),
            'ghost'),
        throwsA(isA<SessionStoreException>()));
  });

  test('close ends the link; the session keeps its log in memory', () async {
    final host = Host.start(
        _config(tmp, [
          [scriptedReply('x')]
        ]),
        sessionId: 's-1');
    await host.send('q');
    final stored =
        host.config.plugins.whereType<PersistencePlugin>().single.store;
    host.close();
    expect(() => stored.list(), throwsA(isA<SessionStoreException>()));
    expect(host.session.loop.log, isNotEmpty);
    host.close(); // idempotent
  });

  test('failed resume closes the opened store before creating a provider', () {
    final opened = SessionStore.open(dbPath);
    var providers = 0;
    final config = HostConfig(
      workingDirectory: tmp.path,
      providerFactory: (_) {
        providers++;
        return ScriptedProvider(const []);
      },
      plugins: [PersistencePlugin(openStore: () => opened)],
    );
    expect(() => Host.resume(config, 'missing'),
        throwsA(isA<SessionStoreException>()));
    expect(providers, 0);
    expect(() => opened.list(), throwsA(isA<SessionStoreException>()));
  });

  test('opening and quitting without activity does not save a session', () {
    final first = Host.start(_config(tmp, []), sessionId: 'unused');
    final persistence =
        first.config.plugins.whereType<PersistencePlugin>().single;
    persistence.sessionChanged(first.context);
    expect(persistence.registryKey, isNull);
    expect(persistence.store.list(), isEmpty);
    first.close();
    final store = SessionStore.open(dbPath);
    addTearDown(store.close);
    expect(store.list(), isEmpty);
  });

  test('enabling persistence after activity captures the existing history',
      () async {
    final host =
        Host.start(_config(tmp, [], persist: false), sessionId: 'late');
    await host.send('hello');
    final plugin =
        PersistencePlugin(openStore: () => SessionStore.open(dbPath));
    host.attachPlugin(plugin);
    expect(plugin.store.list().single.id, 'late');
    expect(
        plugin.store.readEntries('late').length, host.session.loop.log.length);
    expect(plugin.store.checkGaps('late'), isEmpty);
    host.close();
  });

  test('starting an existing session refuses to append a second history',
      () async {
    final first = Host.start(_config(tmp, []), sessionId: 'existing');
    await first.send('hello');
    first.close();
    expect(() => Host.start(_config(tmp, []), sessionId: 'existing'),
        throwsA(isA<SessionStoreException>()));
    final store = SessionStore.open(dbPath);
    addTearDown(store.close);
    expect(store.list(), hasLength(1));
    expect(store.readEntries('existing'), isNotEmpty);
  });
}
