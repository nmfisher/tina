import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_persistence/tina_persistence.dart';

final class _Probe extends AgentPlugin {
  _Probe({this.prepare, this.ended});
  final void Function()? prepare;
  final void Function()? ended;
  var toolsRun = 0;
  @override
  String get id => 'test/probe';
  @override
  void prepareTurn(TurnContext context) => prepare?.call();
  @override
  void onTurnEnd(TurnContext context) => ended?.call();
  @override
  List<ToolSchema> get tools => [
        ToolSchema(
            name: 'probe',
            description: 'probe',
            inputSchema: {'type': 'object', 'properties': {}})
      ];
  @override
  void mountOn(AgentLoop loop) {
    loop.registerExecutor('probe', (_) async {
      toolsRun++;
      return ToolResult('result');
    });
  }
}

void main() {
  late Directory dir;
  late String path;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina-durable-');
    path = '${dir.path}/sessions.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void refuse(String condition) {
    final db = sqlite3.open(path);
    db.execute('''CREATE TRIGGER refuse BEFORE INSERT ON log_registry
      WHEN $condition BEGIN SELECT RAISE(ABORT, 'injected failure'); END''');
    db.close();
  }

  List<SessionEntry> read() {
    final store = SessionStore.open(path);
    try {
      return store.readEntries('session');
    } finally {
      store.close();
    }
  }

  test('raw input commits before preparation and completion before end hooks',
      () async {
    var prepared = false;
    var ended = false;
    final probe = _Probe(prepare: () {
      expect(read().map((e) => e.kind), ['turn_started', 'input_recorded']);
      // Arbitrary hooks run with no write transaction held by persistence.
      final other = sqlite3.open(path);
      other.execute('BEGIN IMMEDIATE');
      other.execute('ROLLBACK');
      other.close();
      prepared = true;
    }, ended: () {
      expect(read().last, isA<TurnEndedEntry>());
      expect(read().whereType<MessageAppendedEntry>().last.message.role,
          Role.assistant);
      ended = true;
    });
    final host = Host.start(
        HostConfig(
            workingDirectory: dir.path,
            providerFactory: (_) => ScriptedProvider([scriptedReply('done')]),
            plugins: [
              PersistencePlugin(openStore: () => SessionStore.open(path)),
              probe
            ]),
        sessionId: 'session');
    addTearDown(host.close);
    await host.send('raw');
    expect(prepared && ended, isTrue);
  });

  final failures = <String, (String, int, int)>{
    'raw input': (
      "json_extract(NEW.payload, '\$.type') = 'input_recorded'",
      0,
      0
    ),
    'processed input': (
      "json_extract(NEW.payload, '\$.message.role') = 'user'",
      0,
      0
    ),
    'tool request': (
      "json_extract(NEW.payload, '\$.message.role') = 'assistant'",
      1,
      0
    ),
    'first tool result': (
      "json_extract(NEW.payload, '\$.message.content[0].type') = 'tool_result'",
      1,
      1
    ),
  };
  for (final failure in failures.entries) {
    test('${failure.key} failure blocks dependent provider/tool execution',
        () async {
      final probe = _Probe();
      final provider = ScriptedProvider([
        scriptedReply('', calls: [
          const ToolUseBlock(id: 'one', name: 'probe', input: {}),
          const ToolUseBlock(id: 'two', name: 'probe', input: {}),
        ]),
        scriptedReply('done'),
      ]);
      final persistence =
          PersistencePlugin(openStore: () => SessionStore.open(path));
      final host = Host.start(
          HostConfig(
              workingDirectory: dir.path,
              providerFactory: (_) => provider,
              plugins: [persistence, probe]),
          sessionId: 'session');
      refuse(failure.value.$1);
      await expectLater(
          host.send('hello'), throwsA(isA<SessionStoreException>()));
      expect(provider.callCount, failure.value.$2);
      expect(probe.toolsRun, failure.value.$3);
      expect(host.session.turns, isEmpty);
      // An attempted next turn cannot bypass the failed persistence callback.
      await expectLater(
          host.send('again'), throwsA(isA<SessionStoreException>()));
      expect(provider.callCount, failure.value.$2);
      if (failure.key == 'raw input') {
        expect(persistence.registryKey, isNull);
        final recovered = SessionStore.open(path);
        expect(recovered.list(), isEmpty);
        recovered.close();
      }
      expect(host.close, throwsA(isA<SessionStoreException>()));
    });
  }

  test(
      'failed end commit rolls back final reply and does not report completion',
      () async {
    var completed = false;
    final host = Host.start(
        HostConfig(
            workingDirectory: dir.path,
            providerFactory: (_) => ScriptedProvider([scriptedReply('done')]),
            plugins: [
              PersistencePlugin(openStore: () => SessionStore.open(path)),
              _Probe(ended: () {
                completed = true;
              })
            ]),
        sessionId: 'session');
    refuse("json_extract(NEW.payload, '\$.type') = 'turn_ended'");
    await expectLater(
        host.send('hello'), throwsA(isA<SessionStoreException>()));
    expect(completed, isFalse);
    expect(host.session.turns, isEmpty);
    expect(read().map((e) => e.kind),
        ['turn_started', 'input_recorded', 'message_appended']);
    expect(read().whereType<MessageAppendedEntry>().single.message.role,
        Role.user);
    expect(host.close, throwsA(isA<SessionStoreException>()));
  });

  test(
      'runtime enable registers and saves history atomically, with no replay duplicates',
      () async {
    final provider =
        ScriptedProvider([scriptedReply('first'), scriptedReply('second')]);
    final host = Host.start(
        HostConfig(
            workingDirectory: dir.path,
            providerFactory: (_) => provider,
            plugins: []),
        sessionId: 'session');
    addTearDown(host.close);
    await host.send('one');
    SessionStore.open(path).close();
    refuse("json_extract(NEW.payload, '\$.type') = 'input_recorded'");
    final failed = PersistencePlugin(openStore: () => SessionStore.open(path));
    expect(
        () => host.attachPlugin(failed), throwsA(isA<SessionStoreException>()));
    expect(failed.registryKey, isNull);
    final db = sqlite3.open(path);
    expect(db.select('SELECT * FROM log_registry'), isEmpty);
    db.execute('DROP TRIGGER refuse');
    db.close();
    host.attachPlugin(
        PersistencePlugin(openStore: () => SessionStore.open(path)));
    expect(read().map((e) => e.toJson()),
        host.session.loop.log.map((e) => e.toJson()));
    await host.send('two');
    expect(read().map((e) => e.seq), List.generate(10, (i) => i));
  });

  test('parent and child batches preserve their independent sequence numbers',
      () {
    final parent = SessionStore.open(path);
    final child = SessionStore.open(path);
    addTearDown(parent.close);
    addTearDown(child.close);
    List<SessionEntry> batch(int start) => [
          TurnStartedEntry(turnId: 't$start', seq: start),
          InputRecordedEntry(turnId: 't$start', text: 'hello', seq: start + 1),
        ];
    parent.createSession('parent', entries: batch(0));
    child.createSession('child', entries: batch(0));
    parent.append('parent', batch(2));
    child.append('child', batch(2));
    for (final id in ['parent', 'child']) {
      expect(parent.readEntries(id).map((e) => e.seq), [0, 1, 2, 3]);
      expect(parent.checkGaps(id), isEmpty);
    }
  });
}
