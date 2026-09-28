import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_persistence/tina_persistence.dart';

const question = Message(role: Role.user, content: [TextBlock('hello')]);
const answer = Message(
    role: Role.assistant,
    content: [TextBlock('world')],
    reasoning: [ReasoningBlock('local thought', signature: 'signed')]);
void main() {
  late Directory dir;
  late SessionStore store;
  const importer = LegacySessionImporter();
  setUp(() {
    dir = Directory.systemTemp.createTempSync('legacy-import-');
    store = SessionStore.open('${dir.path}/target.db');
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });
  File transcript(String path, List<Message> messages) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
        '${messages.map((m) => jsonEncode(m.toJson())).join('\n')}\n');
  File manifest(
          {int version = 2,
          bool local = false,
          List<Map<String, dynamic>>? conversations}) =>
      File('${dir.path}/source/s/session.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({
          'version': version,
          'id': 's',
          'providerId': 'old-provider',
          'cwd': '${dir.path}/workspace',
          'transcriptsLocal': local,
          'activeConversationId': 'c',
          'usage': {'tokens': 1234},
          'conversations': conversations ??
              [
                {
                  'id': 'c',
                  'model': 'old/model',
                  'policy': {'mode': 'unrestricted'}
                }
              ],
        }));
  List<Message> history(String id) =>
      deriveSession(store.readEntries(id), const SessionSettings()).messages;

  test(
      'flat snapshot preserves content/reasoning and survives resume without replay',
      () async {
    final file = transcript('${dir.path}/flat.jsonl', [
      question,
      answer,
      const Message(
          role: Role.assistant,
          content: [ToolUseBlock(id: 'call', name: 'dangerous', input: {})]),
    ]);
    final before = file.readAsBytesSync();
    final result = importer.importPath(file.path, store: store).single;
    expect(result.status, LegacyImportStatus.imported);
    expect(result.warnings.single, contains('execution-unknown'));
    expect(history(result.id!)[1].reasoning.single.signature, 'signed');
    expect(history(result.id!).last.content.single, isA<ToolResultBlock>());
    expect(store.checkGaps(result.id!), isEmpty);
    final provider = ScriptedProvider([scriptedReply('continued')]);
    final host = Host.resume(
        HostConfig(
            providerFactory: (_) => provider,
            workingDirectory: dir.path,
            plugins: [
              PersistencePlugin(openStore: () => SessionStore.open(store.file))
            ]),
        result.id!);
    addTearDown(host.close);
    var executions = 0;
    host.session.loop.registerExecutor('dangerous', (_) async {
      executions++;
      return const ToolResult('bad');
    });
    expect(provider.requests, isEmpty);
    await host.send('continue');
    expect(executions, 0);
    expect(
        provider.requests.single.messages
            .map((m) => jsonEncode(m.toJson()))
            .join(),
        contains('Execution status is unknown'));
    expect(importer.importPath(file.path, store: store).single.status,
        LegacyImportStatus.skipped);
    expect(file.readAsBytesSync(), before);
  });
  for (final version in [1, 2]) {
    test('v$version global layout translates trackers and preserves metadata',
        () {
      final file = manifest(version: version, conversations: [
        {
          'id': 'c',
          'model': 'old/model',
          'plan': {
            'items': [
              {'text': 'step', 'state': 'inProgress'}
            ],
            'approval': 'requested'
          },
          'goal': {
            'text': 'objective',
            'status': {
              'verdict': 'uncertain',
              'evidence': 'needs check',
              'at': 'then'
            }
          },
        }
      ]);
      transcript('${file.parent.path}/c.jsonl', [question, answer]);
      final result = importer.importPath(file.parent.path, store: store).single;
      expect(result.status, LegacyImportStatus.imported);
      expect(result.active, true);
      final derived =
          deriveSession(store.readEntries(result.id!), const SessionSettings());
      expect(derived.plan!.items.single.state, 'in_progress');
      expect(derived.goal!.text, 'objective');
      expect(derived.mode, 'normal');
      expect(derived.pendingTurnId, isNull);
      final metadata =
          store.readLog(result.id!).first.payload['legacy_import'] as Map;
      expect((metadata['manifest'] as Map)['usage'], {'tokens': 1234});
      expect(store.readDetails(result.id!).tokensSpent, 0);
    });
  }
  test(
      'local sidecar wins, global fallback works, missing conversations report separately',
      () {
    final file = manifest(local: true, conversations: [
      {'id': 'c'},
      {'id': 'fallback'},
      {'id': 'missing'}
    ]);
    transcript(
        '${dir.path}/workspace/.tina/sessions/s/c.jsonl', [question, answer]);
    transcript('${file.parent.path}/c.jsonl', [question]);
    transcript('${file.parent.path}/fallback.jsonl', [answer]);
    final result = importer.importPath('${dir.path}/source', store: store);
    expect(result.map((r) => r.status), [
      LegacyImportStatus.imported,
      LegacyImportStatus.imported,
      LegacyImportStatus.failed
    ]);
    expect(history(result.first.id!).length, 2);
    expect(store.list().length, 2);
  });
  test('coalesces tool results and preserves synthetic markers', () {
    final file = transcript('${dir.path}/flat.jsonl', [
      const Message(
          role: Role.user, content: [TextBlock('summary')], isSynthetic: true),
      const Message(role: Role.assistant, content: [
        ToolUseBlock(id: 'a', name: 'x', input: {}),
        ToolUseBlock(id: 'b', name: 'x', input: {})
      ]),
      const Message(
          role: Role.user,
          content: [ToolResultBlock(toolUseId: 'a', content: 'one')]),
      const Message(role: Role.user, content: [
        ToolResultBlock(toolUseId: 'b', content: 'two', isError: true)
      ]),
    ]);
    final result = importer.importPath(file.path, store: store).single;
    expect(result.warnings, isEmpty);
    expect(history(result.id!).first.isSynthetic, true);
    expect(history(result.id!).last.content.length, 2);
  });
  test(
      'dry run never writes, repeats skip, changed sources and collisions fail',
      () {
    final file = transcript('${dir.path}/flat.jsonl', [question]);
    expect(
        importer.importPath(file.path).single.status, LegacyImportStatus.ready);
    expect(store.list(), isEmpty);
    expect(importer.importPath(file.path, store: store).single.status,
        LegacyImportStatus.imported);
    expect(importer.importPath(file.path, store: store).single.status,
        LegacyImportStatus.skipped);
    transcript(file.path, [question, answer]);
    expect(importer.importPath(file.path, store: store).single.status,
        LegacyImportStatus.failed);
    expect(history('legacy:flat:flat').length, 1);
    store.createSession('legacy:other:other');
    final other = transcript('${dir.path}/other.jsonl', [question]);
    expect(importer.importPath(other.path, store: store).single.status,
        LegacyImportStatus.failed);
  });
  test('malformed tail and unknown block reject the whole conversation', () {
    final file = transcript('${dir.path}/bad.jsonl', [question]);
    file.writeAsStringSync('{"role":', mode: FileMode.append);
    expect(importer.importPath(file.path, store: store).single.error,
        contains('line 2'));
    expect(store.list(), isEmpty);
    file.writeAsStringSync(
        '{"role":"assistant","content":[{"type":"future"}]}\n');
    expect(importer.importPath(file.path, store: store).single.status,
        LegacyImportStatus.failed);
    expect(store.list(), isEmpty);
  });
  test('unsafe IDs and unknown manifest versions fail without destination rows',
      () {
    final file = manifest(version: 99);
    expect(importer.importPath(file.path, store: store).single.status,
        LegacyImportStatus.failed);
    manifest(conversations: [
      {'id': '../escape'}
    ]);
    expect(importer.importPath(file.path, store: store).single.status,
        LegacyImportStatus.failed);
    expect(store.list(), isEmpty);
  });
  test('an insertion failure rolls back both registry and entry rows', () {
    // Fail after the registry marker has been inserted, inside the transaction.
    final db = sqlite3.open(store.file);
    db.execute(
        "CREATE TRIGGER fail_import BEFORE INSERT ON log_registry WHEN json_extract(NEW.payload, '\$.type') = 'message_appended' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END");
    db.close();
    final file = transcript('${dir.path}/flat.jsonl', [question]);
    expect(importer.importPath(file.path, store: store).single.status,
        LegacyImportStatus.failed);
    // The failed link is poisoned; inspect the file through a fresh connection.
    store = SessionStore.open(store.file);
    expect(store.list(), isEmpty);
  });
}
