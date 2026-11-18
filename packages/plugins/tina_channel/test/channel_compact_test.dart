import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';
import 'package:tina_channel/tina_channel.dart';
import 'package:tina_channel/tina_channel_sqlite.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// Phase 4 — channel_compact: the compaction point, the digest, the
/// access rule and the audit-trail discipline (views shrink, rows
/// never leave).
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina_compact_test');
    path = '${dir.path}/chat.db';
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {}
  });

  SqliteChannelStore open() => SqliteChannelStore.open(path);

  void fill(SqliteChannelStore store, int count) {
    for (var i = 1; i <= count; i++) {
      store.post('#work', sender: 'agent-a', text: 'message $i');
    }
  }

  Future<ToolResult> run(ChannelTools tools, Map<String, Object?> input) =>
      tools.execute('channel_compact', input);

  test('compact writes a digest and reads respect the point', () async {
    final store = open();
    fill(store, 30);
    final tools =
        ChannelTools(store: store, agentName: 'main-agent', role: 'main');
    final result = await run(tools, {'channel': '#work', 'mode': 'compact'});
    expect(result.isError, isFalse, reason: result.content);

    final view = store.read('#work', limit: 200);
    // the kept tail + the digest (append-only: the digest lands at the
    // newest id, after everything it summarizes) — the 10 oldest
    // messages left the view.
    expect(view.length, compactDefaultKeep + 1);
    expect(view.last.type, ChannelMessageType.system);
    expect(view.last.sender, 'main-agent');
    expect(view.last.text, contains('superseded 10 messages'));
    expect(view.last.text, contains('ids 1–10'));
    // The retained tail is the NEWEST material, in order.
    expect(view.first.text, 'message 11');
    expect(view[compactDefaultKeep - 1].text, 'message 30');
    expect(store.compactionPoint('#work'), 10,
        reason: 'the point sits below the oldest retained row (11)');
  });

  test('the database retains the full history (audit discipline)', () async {
    final store = open();
    fill(store, 30);
    store.compact('#work', actor: 'main-agent');
    final raw = sqlite3.sqlite3.open(path);
    addTearDown(raw.close);
    final rows = raw
        .select('SELECT COUNT(*) AS n FROM messages WHERE channel = ?', ['#work'])
        .single['n'] as int;
    expect(rows, 31, reason: '30 messages + 1 digest; nothing deleted');
  });

  test('clear empties the view but keeps rows, identity and membership',
      () {
    final store = open();
    fill(store, 12);
    store.setMember('#work', 'agent-a', status: 'working', announce: false);
    final result = store.compact('#work', actor: 'human', clear: true);
    expect(result.digested, 12);
    expect(result.digestId, 0, reason: 'a clear writes no digest');

    expect(store.read('#work', limit: 100), isEmpty);
    expect(store.members('#work').single.name, 'agent-a',
        reason: 'membership survives');
    // New life continues in the same room.
    store.post('#work', sender: 'agent-a', text: 'fresh start');
    expect(store.read('#work').single.text, 'fresh start');

    final raw = sqlite3.sqlite3.open(path);
    addTearDown(raw.close);
    final rows = raw
        .select('SELECT COUNT(*) AS n FROM messages WHERE channel = ?', ['#work'])
        .single['n'] as int;
    expect(rows, 13, reason: '12 originals + the new post, all retained');
  });

  test('compounding never resurrects superseded rows', () async {
    final store = open();
    fill(store, 30);
    store.compact('#work', actor: 'main', keep: 20);
    for (var i = 31; i <= 35; i++) {
      store.post('#work', sender: 'agent-a', text: 'message $i');
    }
    store.compact('#work', actor: 'main', keep: 100);
    final view = store.read('#work', limit: 200);
    // Second compaction with keep=100 retains the whole current view;
    // ids 1-10 never return — checked by ID, not text (the texts
    // repeat across fills).
    expect(view.any((m) => m.id <= 10), isFalse,
        reason: 'superseded rows stay superseded');
    expect(view.any((m) => m.text == 'message 35'), isTrue);
  });

  test('subagents are refused with a normal tool error', () async {
    final store = open();
    fill(store, 5);
    final sub =
        ChannelTools(store: store, agentName: 'child', role: 'subagent');
    final result = await run(sub, {'channel': '#work', 'mode': 'compact'});
    expect(result.isError, isTrue);
    expect(result.content, contains('main agent'));
    expect(store.compactionPoint('#work'), 0,
        reason: 'the refusal changed nothing');

    final cleared = await run(sub, {'channel': '#work', 'mode': 'clear'});
    expect(cleared.isError, isTrue);
    expect(store.read('#work', limit: 10).length, 5);
  });

  test('the marker survives a resume (fresh connection)', () async {
    final first = open();
    fill(first, 25);
    first.compact('#work', actor: 'main-agent', keep: 10);
    first.close();

    final resumed = open();
    final view = resumed.read('#work', limit: 200);
    expect(view.length, 11, reason: '10 kept + digest');
    expect(view.last.type, ChannelMessageType.system);
    resumed.close();
  });

  test('the in-memory twin has the same semantics', () async {
    final store = InMemoryChannelStore();
    for (var i = 1; i <= 30; i++) {
      store.post('#work', sender: 'a', text: 'message $i');
    }
    final compaction = store.compact('#work', actor: 'main', keep: 20);
    expect(compaction.digested, 10);
    expect(compaction.superseded.length, 10);
    expect(compaction.superseded.first.text, 'message 1');
    final view = store.read('#work', limit: 200);
    expect(view.length, 21);
    expect(view.last.type, ChannelMessageType.system);
  });

  test('the issue-94 hook receives the superseded span', () async {
    final store = open();
    fill(store, 15);
    ChannelCompaction? seen;
    final tools = ChannelTools(
        store: store,
        agentName: 'main-agent',
        role: 'main',
        onCompacted: (c) => seen = c);
    await run(tools, {'channel': '#work', 'mode': 'compact', 'keep': 5});
    expect(seen, isNotNull,
        reason: 'the memory-extraction seam fired');
    expect(seen!.superseded.length, 10,
        reason: 'exactly the distilled span travels');
    expect(seen!.superseded.first.text, 'message 1');
  });
}
