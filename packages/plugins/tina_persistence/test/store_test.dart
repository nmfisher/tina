// The session store: one file, registry-markers-in-one-log, poison-pill
// fail-loud, and the same-bytes property against a JSON Lines twin.
//
// Run: dart test
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_sqlite/tina_sqlite.dart';

/// A tiny finished turn as a store client would hand it over: start,
/// raw input, the user message, the end. Seqs stamped by [entries].
List<SessionEntry> turnEntries(String turnId, String text, int from) => [
      TurnStartedEntry(turnId: turnId, at: '2026-01-01T00:00:00Z')
          .withSeq(from),
      InputRecordedEntry(turnId: turnId, text: text, at: 'a').withSeq(from + 1),
      MessageAppendedEntry(
        turnId: turnId,
        message: Message(role: Role.user, content: [TextBlock(text)]),
        at: 'a',
      ).withSeq(from + 2),
      MessageAppendedEntry(
        turnId: turnId,
        message: Message(role: Role.assistant, content: [TextBlock('reply')]),
        at: 'a',
      ).withSeq(from + 3),
      TurnEndedEntry(turnId: turnId, reason: TurnStopReason.complete)
          .withSeq(from + 4),
    ];

void main() {
  late Directory tmp;
  late String path;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tina_store_');
    path = '${tmp.path}/sessions.db';
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('open creates the file; reopen reads it back; schema refuses newer', () {
    final store = SessionStore.open(path);
    expect(File(path).existsSync(), isTrue);
    store.createSession('s-1', title: 'first');
    store.close();

    final again = SessionStore.open(path);
    expect([for (final s in again.list()) s.id], ['s-1']);
    again.close();
  });

  test('round-trip: entries keep their payload bytes and their seq', () {
    final store = SessionStore.open(path);
    store.createSession('s-1');
    final entries = turnEntries('t1', 'hello', 0);
    store.append('s-1', entries);

    final back = store.readEntries('s-1');
    expect(back.length, entries.length);
    for (var i = 0; i < entries.length; i++) {
      expect(jsonEncode(back[i].toJson()), jsonEncode(entries[i].toJson()),
          reason: 'row $i');
      expect(back[i].seq, i);
    }
    store.close();
  });

  test(
      'rows hold one JSON object per row — the same bytes a JSON Lines '
      'twin holds', () {
    final store = SessionStore.open(path);
    store.createSession('s-1');
    final entries = turnEntries('t1', 'hello', 0);
    store.append('s-1', entries);

    // The twin: same entries, plain file. The store's rows wrap each
    // entry with `slice` — the session attribution — so the twin wraps
    // the same way; the entry bytes themselves still match exactly.
    final twin = TinaJsonLinesFile('${tmp.path}/twin.jsonl');
    for (final e in entries) {
      twin.append({'slice': 's-1', ...e.toJson()});
    }

    // The store's rows carry exactly the twin's bytes.
    final twinLines = File('${tmp.path}/twin.jsonl')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final log = store.readLog('s-1');
    expect(log.length, entries.length + 1); // + registry row
    for (var i = 0; i < entries.length; i++) {
      expect(jsonEncode(log[i + 1].payload), twinLines[i],
          reason: 'payload bytes must match the JSON Lines twin');
    }
    store.close();
  });

  test('two sessions, one file: slices stay separate, list is cheap', () {
    final store = SessionStore.open(path);
    store.createSession('s-1');
    store.append('s-1', turnEntries('t1', 'first', 0));
    store.createSession('s-2', title: 'second');
    store.append('s-2', turnEntries('t1', 'second', 0));

    final sessions = store.list();
    expect([for (final s in sessions) s.id], ['s-1', 's-2']);
    expect(sessions[1].title, 'second');
    expect(sessions[0].entries, 5);
    expect(sessions[1].entries, 5);

    expect((store.readEntries('s-1').last as TurnEndedEntry).turnId, 't1');
    expect(
      (store.readEntries('s-2').first as TurnStartedEntry).turnId,
      't1',
      reason: 'slices are independent; seqs restart per session',
    );
    expect(store.checkGaps('s-1'), isEmpty);
    expect(store.checkGaps('s-2'), isEmpty);
    store.close();
  });

  test(
      'an unknown session id throws; repeated session metadata is folded '
      'in list', () {
    final store = SessionStore.open(path);
    expect(
        () => store.readEntries('nope'), throwsA(isA<SessionStoreException>()));
    expect(
        () => store.checkGaps('nope'), throwsA(isA<SessionStoreException>()));
    store.createSession('s-1');
    store.createSession('s-1');
    expect(store.list(), hasLength(1));
    store.close();
  });

  test(
      'interleaved sessions keep their slices attributed — a parent '
      'appending after a child registered does not leak into the child', () {
    final store = SessionStore.open(path);
    store.createSession('parent');
    store.append('parent', turnEntries('t1', 'before', 0));
    store.createSession('child');
    store.append('child', turnEntries('t1', 'child turn', 0));
    // The parent keeps writing after the child exists — the spawn-shape
    // that misfiled under contiguous slices.
    store.append('parent', [
      ...turnEntries('t2', 'after', 5),
    ]);
    store.append('child', turnEntries('t2', 'child again', 5));

    final parent = store.readEntries('parent');
    final child = store.readEntries('child');
    final parentTexts =
        parent.whereType<InputRecordedEntry>().map((e) => e.text);
    expect(parentTexts, ['before', 'after'],
        reason: 'both parent turns, in order, none of the child');
    final childTexts = child.whereType<InputRecordedEntry>().map((e) => e.text);
    expect(childTexts, ['child turn', 'child again']);
    // Both slices stay gap-free even though their rows interleave in the
    // file: strictly increasing rowids, seq runs 0,1,2,… per slice.
    expect(store.checkGaps('parent'), isEmpty);
    expect(store.checkGaps('child'), isEmpty);
    store.close();
  });

  test(
      'a hole in the payload seq run is corruption, even when the rowids '
      'are adjacent', () {
    final store = SessionStore.open(path);
    store.createSession('s-1');
    store.append('s-1', turnEntries('t1', 'hello', 0));
    // Drop one entry from the middle of the slice by writing raw rows
    // with a seq hole the log's own API cannot produce.
    final db = sqlite3OpenForTest(path);
    db.execute(
        "DELETE FROM log_registry WHERE payload LIKE '%\"seq\":2%' AND payload LIKE '%\"slice\":\"s-1\"%'");
    db.close();
    final gaps = store.checkGaps('s-1');
    expect(gaps, hasLength(1),
        reason: 'seq 3 follows seq 1: a middle row '
            'is gone, and the file itself carries the evidence');
    store.close();
  });

  test('list folds metadata and counts interleaved entries per session', () {
    final store = SessionStore.open(path);
    addTearDown(store.close);
    final key = store.createSession('parent', title: 'original');
    store.append('parent', turnEntries('t1', 'before', 0));
    store.createSession('child', details: SessionDetails(depth: 1));
    store.append('child', turnEntries('t1', 'child', 0));
    store.updateDetails('parent', SessionDetails(tokensSpent: 42));
    store.append('parent', turnEntries('t2', 'after', 5));
    final sessions = store.list();
    expect(sessions, hasLength(2));
    expect(sessions.first.registryKey, key);
    expect(sessions.first.title, 'original');
    expect(sessions.first.details!.tokensSpent, 42);
    expect(sessions.first.entries, 10);
    expect(sessions.last.entries, 5);
    expect(sessions.last.details!.depth, 1);
  });

  test('a missing first entry is corruption', () {
    final store = SessionStore.open(path);
    addTearDown(store.close);
    store.createSession('s-1');
    store.append('s-1', turnEntries('t1', 'hello', 0).skip(1).toList());
    expect(store.checkGaps('s-1'), hasLength(1));
  });

  test('an unreadable entry payload throws — no silent skimming', () {
    final store = SessionStore.open(path);
    store.createSession('s-1');
    store.append('s-1', turnEntries('t1', 'hello', 0));
    // Slip an unknown entry type into the slice from outside the API —
    // attributed like any real row, so the slice cannot dodge the decode
    // by losing its name.
    final db = sqlite3OpenForTest(path);
    db.execute(
        "INSERT INTO log_registry (at, payload) VALUES ('x', '{\"slice\":\"s-1\",\"type\":\"session_nuked\"}')");
    db.close();
    // The unknown type surfaces as a store failure naming the session,
    // with the decode error as the cause — loud, never skimmed.
    try {
      store.readEntries('s-1');
      fail('expected the unreadable payload to throw');
    } on SessionStoreException catch (e) {
      expect(e.cause, isA<FormatException>());
    }
    store.close();
  });

  test('after close every call throws through the poison pill', () {
    final store = SessionStore.open(path);
    store.createSession('s-1');
    store.close();
    expect(() => store.list(), throwsA(isA<SessionStoreException>()));
    expect(
        () => store.readEntries('s-1'), throwsA(isA<SessionStoreException>()));
  });
}

/// The tests need one raw peek at the file; opening it directly keeps
/// the store's own API the only writer under test.
Database sqlite3OpenForTest(String path) => sqlite3.open(path);
