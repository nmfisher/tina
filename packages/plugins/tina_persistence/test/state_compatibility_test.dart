import 'dart:io';
import 'dart:convert';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persistence/tina_persistence.dart';

void main() {
  test('opening old SQLite rows normalizes in memory without rewriting bytes',
      () {
    final tmp = Directory.systemTemp.createTempSync('old-plugin-rows-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/sessions.db';
    final store = SessionStore.open(path);
    addTearDown(store.close);
    store.createSession('one');
    store.createSession('two');
    final db = sqlite3.open(path);
    addTearDown(db.close);
    final original = jsonEncode({
      'slice': 'one',
      'seq': 0,
      'type': 'plan_changed',
      'items': [],
      'approval': 'none'
    });
    db.execute('INSERT INTO log_registry (at, payload) VALUES (?, ?)',
        ['old', original]);
    db.execute('INSERT INTO log_registry (at, payload) VALUES (?, ?)', [
      'old',
      jsonEncode({'slice': 'two', 'seq': 0, 'type': 'goal_changed', 'text': ''})
    ]);
    final one = store.readEntries('one').single as PluginStateEntry;
    expect(one.pluginId, 'tina/plans');
    expect((store.readEntries('two').single as PluginStateEntry).pluginId,
        'tina/goals');
    expect(
        db.select(
            'SELECT payload FROM log_registry WHERE payload = ?', [original]),
        hasLength(1));
    store.append('one', [
      PluginStateEntry.snapshot(
          pluginId: 'other/future',
          stateKey: 'key',
          schemaVersion: 88,
          value: null,
          seq: 1)
    ]);
    expect(store.readEntries('one').map((e) => e.seq), [0, 1]);
    expect(
        db.select(
            'SELECT payload FROM log_registry WHERE payload = ?', [original]),
        hasLength(1));
  });

  test('historical feature rows normalize without losing order or clear values',
      () {
    final old = [
      {'type': 'plan_changed', 'items': [], 'approval': 'none'},
      {'type': 'goal_changed', 'text': ''},
      {'type': 'workflow_run', 'workflow': 'w', 'status': 'success'},
      {'type': 'mode_changed', 'mode': 'normal'},
    ];
    final entries = [
      for (var i = 0; i < old.length; i++)
        decodePersistedEntry({...old[i], 'seq': i, 'at': 'time'})
            as PluginStateEntry
    ];
    expect(entries.map((e) => e.seq), [0, 1, 2, 3]);
    expect(entries.map((e) => e.at).toSet(), {'time'});
    expect(entries.map((e) => e.pluginId),
        ['tina/plans', 'tina/goals', 'tina/workflows', 'tina/mode']);
    expect(entries[0].value!['items'], isEmpty);
    expect(entries[1].value!['text'], '');
    expect(entries[3].value!['mode'], 'ask');
  });

  test('unknown plugin versions and tombstones survive SQLite reopen', () {
    final tmp = Directory.systemTemp.createTempSync('opaque-state-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/sessions.db';
    var store = SessionStore.open(path);
    store.createSession('one');
    store.createSession('two');
    final state = PluginStateEntry.snapshot(
        pluginId: 'other/future',
        stateKey: 'key',
        schemaVersion: 999,
        value: {
          'nested': [
            1,
            {'x': true}
          ]
        });
    store.append('one', [state]);
    store.append('two', [
      PluginStateEntry.snapshot(
          pluginId: 'other/future',
          stateKey: 'key',
          schemaVersion: 999,
          value: null)
    ]);
    store.close();
    store = SessionStore.open(path);
    try {
      expect(store.readEntries('one').single.toJson(), state.toJson());
      expect(
          (store.readEntries('two').single as PluginStateEntry).value, isNull);
    } finally {
      store.close();
    }
  });
}
