// Rewind across the store: the log stays append-only (a rewind marker is
// another row, the removed tail stays on disk and readable), and a resume
// that seeds from the stored slice reopens the session rewound.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persistence/tina_persistence.dart';

import 'store_test.dart' show turnEntries;

void main() {
  late Directory tmp;
  late String path;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tina_rewind_');
    path = '${tmp.path}/sessions.db';
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test(
      'a rewound session stays append-only on disk and reopens rewound '
      'through the persistence seed', () async {
    final store = SessionStore.open(path);
    addTearDown(store.close);

    // Two finished turns, a rewind before the second, then a third turn
    // that continues from the rewound point. The marker is written as the
    // legacy 'rewound' wire type — exactly what a log persisted by the old
    // code holds — so this test pins the compatibility alias end to end.
    final turn1 = turnEntries('t1', 'first', 0);
    final turn2 = turnEntries('t2', 'second', 5);
    final marker = SessionEntry.fromJson(
        {'type': 'rewound', 'to_seq': 5, 'at': 'b', 'seq': 10});
    final turn3 = turnEntries('t3', 'third', 11);

    store.createSession('s', title: 'rewind', entries: turn1);
    store.append('s', turn2);
    store.append('s', [marker]);
    store.append('s', turn3);

    // Append-only: every entry — the rewound tail included — is still on
    // disk, in order, and readable by anything deriving an export.
    final stored = store.readEntries('s');
    expect(stored.length, 16);
    expect(stored[10], isA<CutEntry>());
    expect(stored.whereType<InputRecordedEntry>().map((e) => e.text).toList(),
        ['first', 'second', 'third']);
    expect(store.checkGaps('s'), isEmpty,
        reason: 'seqs stay contiguous across a rewind');

    // The resume seed is the full slice; derivation from it is the rewound
    // conversation — second never happened, third continues from first.
    final loop = AgentLoop(
      provider: ScriptedProvider([scriptedReply('r')]),
      plugins: [],
      seedLog: stored,
    );
    final view = loop.derive();
    expect(
      view.messages.map((m) => (m.content.single as TextBlock).text).toList(),
      ['first', 'reply', 'third', 'reply'],
    );

    // And the next turn appends after everything, without resurrecting the
    // dead tail.
    await loop.runTurn(const Input('fourth', id: 't4'));
    final after = loop.derive();
    expect(
      after.messages.map((m) => (m.content.single as TextBlock).text).toList(),
      ['first', 'reply', 'third', 'reply', 'fourth', 'r'],
    );
  });

  test('the loop is the only writer: rewind through the plugin seed survives',
      () {
    final store = SessionStore.open(path);
    addTearDown(store.close);
    final turn1 = turnEntries('t1', 'only', 0);
    store.createSession('s', entries: turn1);
    store.append('s', [CutEntry(toSeq: 0, at: 'b').withSeq(5)]);

    final stored = store.readEntries('s');
    expect(stored.length, 6);
    final reopened =
        AgentLoop(provider: _IdleProvider(), plugins: [], seedLog: stored);
    expect(reopened.derive().messages, isEmpty,
        reason: 'rewind to the very start derives nothing');
  });
}

final class _IdleProvider implements LlmProvider {
  @override
  String get model => 'idle';

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {}

  @override
  void close() {}
}
