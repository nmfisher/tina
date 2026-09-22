import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/memory_file_system.dart';

const editInput = {
  'filePath': 'pubspec.yaml',
  'oldString': 'version: 0.6.22',
  'newString': 'version: 0.6.23',
};

void main() {
  late _FileSystem fs;
  late EditTool edit;
  late PermissionPolicy policy;
  late List<PermissionPrompt> prompts;
  late PermissionAsker respond;
  late ToolExecutor executor;

  setUp(() {
    fs = _FileSystem({'pubspec.yaml': 'name: tina\nversion: 0.6.22\n'});
    edit = EditTool(fs: fs)..mutationLock = FileMutationLock();
    policy = PermissionPolicy();
    prompts = [];
    respond = (_) async => PermissionResponse.allowOnce;
    executor = ToolExecutor(
        policy: policy,
        asker: (p) async {
          prompts.add(p);
          return respond(p);
        },
        sink: FakeAgentSink(),
        state: ToolCallState(),
        cancelSignal: Completer<void>().future);
  });

  Future<ToolResultBlock> run([Map<String, dynamic> input = editInput]) async =>
      (await executor.execute(
              use: ToolUseBlock(id: 'edit', name: 'edit', input: input),
              stepTools: ToolRegistry([edit]).forStep(),
              step: 0,
              isCancelled: () => false))
          .result;

  test(
      'missing match returns actionable conflict before approval, without writes',
      () async {
    edit.backupStore = BackupStore(fs: fs, storeDir: Directory('/backups'));
    fs.files['pubspec.yaml'] = 'name: tina\nversion: 0.6.23\n';
    final result = await run();
    expect(result.isError, true);
    final data = jsonDecode(result.content) as Map;
    expect(data['code'], 'edit_conflict');
    expect(data['reason'], 'missingMatch');
    expect(data['replacementTextPresent'], true);
    expect(data['fileModifiedByThisEdit'], false);
    expect(data['recovery'], contains('not proof'));
    expect(
        (data['currentContext'] as Map)['lines'], contains('version: 0.6.23'));
    expect(prompts, isEmpty);
    expect(fs.writes, 0);
    expect(fs.files.keys, ['pubspec.yaml'], reason: 'no backup or temp files');
  });

  test('ambiguous matches are caught before approval', () async {
    fs.files['pubspec.yaml'] = 'version: 0.6.22\nversion: 0.6.22';
    final result = await run();
    expect((jsonDecode(result.content) as Map)['matchCount'], 2);
    expect(prompts, isEmpty);
    expect(fs.writes, 0);
  });

  test('a corrected retry receives approval and applies exactly once',
      () async {
    fs.files['pubspec.yaml'] = 'version: 0.6.21';
    expect((await run()).isError, true);
    expect((await run({...editInput, 'oldString': 'version: 0.6.21'})).isError,
        false);
    expect(prompts, hasLength(1));
    expect(fs.files['pubspec.yaml'], 'version: 0.6.23');
    expect(fs.writes, 1);
  });

  test('preview and execution use the prepared arguments even if input mutates',
      () async {
    final input = Map<String, dynamic>.from(editInput);
    respond = (p) async {
      expect(p.preparedEdit, isNotNull);
      input['newString'] = 'version: unapproved';
      final preview =
          await previewToolCall('edit', input, preparedEdit: p.preparedEdit);
      expect(preview.whereType<PreviewAdded>().single.text, 'version: 0.6.23');
      expect(preview.whereType<PreviewContext>().single.text,
          contains('Verified'));
      expect(fs.writes, 0);
      return PermissionResponse.allowOnce;
    };
    expect((await run(input)).isError, false);
    expect(fs.files['pubspec.yaml'], 'name: tina\nversion: 0.6.23\n');
  });

  test('file changes during approval reject even when oldString still matches',
      () async {
    edit.backupStore = BackupStore(fs: fs, storeDir: Directory('/backups'));
    respond = (_) async {
      // A different region changed: do not overwrite or silently rebase an
      // approved edit onto a different snapshot.
      fs.files['pubspec.yaml'] = 'name: changed\nversion: 0.6.22\n';
      return PermissionResponse.allowOnce;
    };
    final result = await run();
    expect((jsonDecode(result.content) as Map)['reason'], 'fileChanged');
    expect(fs.files['pubspec.yaml'], 'name: changed\nversion: 0.6.22\n');
    expect(fs.writes, 0);
    expect(fs.files.keys, ['pubspec.yaml']);
  });

  test('another agent can edit while approval is pending without a held lock',
      () async {
    respond = (_) async {
      final other = await edit.execute({
        ...editInput,
        'oldString': 'name: tina',
        'newString': 'name: renamed'
      });
      expect(other.isError, false);
      return PermissionResponse.allowOnce;
    };
    final result = await run().timeout(const Duration(seconds: 2));
    expect((jsonDecode(result.content) as Map)['reason'], 'fileChanged');
    expect(fs.files['pubspec.yaml'], 'name: renamed\nversion: 0.6.22\n');
  });

  test('replaceAll cannot silently include matches added after approval',
      () async {
    respond = (_) async {
      fs.files['pubspec.yaml'] = '${fs.files['pubspec.yaml']}version: 0.6.22';
      return PermissionResponse.allowOnce;
    };
    expect((await run({...editInput, 'replaceAll': true})).isError, true);
    expect(fs.writes, 0);
  });

  test('denied and read-all edits never pre-read or prompt', () async {
    policy.remember('edit', '*', PermissionDecision.deny);
    expect((await run()).isError, true);
    policy.sessionRules.clear();
    policy.mode = PermissionMode.readAll;
    expect((await run()).isError, true);
    expect(fs.reads, 0);
    expect(prompts, isEmpty);
  });

  test(
      'unreadable file fails before approval without escaping the tool boundary',
      () async {
    fs.failRead = true;
    expect((await run()).content, contains('Unable to read edit target'));
    expect(prompts, isEmpty);
    expect(fs.writes, 0);
  });

  test('malformed match parameters fail before reads or approval', () async {
    for (final input in [
      {...editInput, 'oldString': 12},
      {...editInput, 'oldString': ''},
      {...editInput, 'replaceAll': 'yes'},
    ]) {
      expect((await run(input)).isError, true);
    }
    expect(fs.reads, 0);
    expect(prompts, isEmpty);
  });

  test('CRLF mismatches remain exact and include bounded current context',
      () async {
    fs.files['pubspec.yaml'] =
        'name: tina\r\nversion: 0.6.22\r\n${'x' * 10000}';
    final result =
        await run({...editInput, 'oldString': 'name: tina\nversion: 0.6.22\n'});
    final data = jsonDecode(result.content) as Map;
    expect(data['lineEndings'], 'contains CRLF');
    expect(result.content.length, lessThan(2500));
    expect(fs.writes, 0);
  });

  test('sandbox validation precedes conflict excerpts or existence probes',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-edit-preflight-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final project = Directory('${dir.path}/project')..createSync();
    final outside = File('${dir.path}/outside')
      ..writeAsStringSync('private-content');
    edit.fs = SandboxedFileSystem(const IoFileSystem(),
        workspaceRoot: project.path, tinaDir: Directory('${dir.path}/data'));
    final result = await run({...editInput, 'filePath': outside.path});
    expect(result.isError, true);
    expect(result.content, isNot(contains('private-content')));
    expect(prompts, isEmpty);
  });
}

class _FileSystem extends MemoryFileSystem {
  int reads = 0;
  int writes = 0;
  bool failRead = false;
  _FileSystem(super.files);
  @override
  Future<String> readFileString(String path) async {
    reads++;
    if (failRead) throw FileSystemException('Permission denied', path);
    return super.readFileString(path);
  }

  @override
  Future<void> writeFile(String path, String content) async {
    writes++;
    await super.writeFile(path, content);
  }
}
