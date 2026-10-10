import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

/// A counting approver: the spy that proves the boundary is consulted exactly
/// once per tool operation.
class CountingApprover {
  int calls = 0;
  final List<({FileOp op, String path})> requests = [];

  Approver get approver => (request, reason) async {
        calls++;
        requests.add(request);
        return Approval.yes;
      };
}

void main() {
  late Directory root;
  late Directory workspace;
  late Directory tinaDir;
  late CountingApprover spy;
  late SandboxedFileSystem sandbox;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tool_file_system_');
    workspace = Directory('${root.path}/workspace')..createSync();
    tinaDir = Directory('${root.path}/.tina')..createSync();
    spy = CountingApprover();
    sandbox = SandboxedFileSystem(
      const IoFileSystem(),
      workspaceRoot: workspace.path,
      tinaDir: tinaDir,
      // ask mode: every out-of-workspace write reaches the approver
      approver: spy.approver,
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('guard fires exactly once per tool operation', () {
    test('write inside the workspace never asks under allowEdits', () async {
      sandbox.mode = PermissionMode.allowEdits;
      final tool = WriteTool(fs: sandbox, workspaceRoot: workspace.path);
      final result =
          await tool.execute({'filePath': 'note.txt', 'content': 'hi'});
      expect(result.isError, isFalse, reason: result.content);
      expect(spy.calls, 0, reason: 'in-project writes are table-allowed');
      expect(File(p.join(workspace.path, 'note.txt')).readAsStringSync(), 'hi');
    });

    test('write inside the workspace still asks once in ask mode', () async {
      final tool = WriteTool(fs: sandbox, workspaceRoot: workspace.path);
      final result =
          await tool.execute({'filePath': 'note.txt', 'content': 'hi'});
      expect(result.isError, isFalse, reason: result.content);
      expect(spy.calls, 1,
          reason: 'ask mode routes every write to the approver — '
              'exactly one dialog for one operation');
      expect(File(p.join(workspace.path, 'note.txt')).readAsStringSync(), 'hi');
    });

    test('write outside the workspace asks exactly once', () async {
      final outside = File(p.join(root.path, 'outside.txt'));
      final tool = WriteTool(fs: sandbox, workspaceRoot: workspace.path);
      final result =
          await tool.execute({'filePath': outside.path, 'content': 'hi'});
      expect(result.isError, isFalse, reason: result.content);
      expect(spy.calls, 1,
          reason: 'one create+write+rename sequence is ONE guarded operation; '
              'the seam methods behind atomicWriteFile already guard, and the '
              'tool no longer stacks a second boundary consult on top');
      expect(outside.readAsStringSync(), 'hi');
    });

    test('edit outside the workspace asks exactly once', () async {
      final outside = File(p.join(root.path, 'outside.txt'))
        ..writeAsStringSync('alpha\n');
      final tool = EditTool(fs: sandbox, workspaceRoot: workspace.path);
      final result = await tool.execute({
        'filePath': outside.path,
        'oldString': 'alpha',
        'newString': 'beta',
      });
      expect(result.isError, isFalse, reason: result.content);
      expect(spy.calls, 1);
      expect(outside.readAsStringSync(), 'beta\n');
    });

    test('read of the Tina data tree is refused exactly once, by the wrapper',
        () async {
      final secret = File(p.join(tinaDir.path, 'session.json'))
        ..writeAsStringSync('{}');
      final tool = ReadTool(fs: sandbox, workspaceRoot: workspace.path);
      final result = await tool.execute({'filePath': secret.path});
      expect(result.isError, isTrue);
      expect(
          result.content, contains('Access to the Tina data tree is blocked'));
      // The guard answered before any probe; a refusal is one consultation.
      expect(spy.calls, 0, reason: 'structural denial happens before the ask');
    });

    test('stat routes through the same wrapper', () async {
      final outside = File(p.join(root.path, 'outside.txt'))
        ..writeAsStringSync('x');
      final tool = StatTool(workspaceRoot: workspace.path, sandbox: sandbox);
      final result = await tool.execute({'path': outside.path});
      expect(result.isError, isFalse, reason: result.content);
      expect(result.content, contains('type: file'));
    });

    test('ls routes through the same wrapper', () async {
      final tool = LsTool(workspaceRoot: workspace.path, sandbox: sandbox);
      final result = await tool.execute({'path': workspace.path});
      expect(result.isError, isFalse, reason: result.content);
    });

    test('glob routes through the same wrapper', () async {
      File(p.join(workspace.path, 'a.txt')).writeAsStringSync('x');
      final tool = GlobTool(workspaceRoot: workspace.path, sandbox: sandbox);
      final result = await tool.execute({'pattern': '*.txt'});
      expect(result.isError, isFalse, reason: result.content);
      expect(result.content, contains('a.txt'));
    });
  });

  group('workspace resolution lives in the wrapper', () {
    test('relative paths resolve against the workspace root', () async {
      final tool = ReadTool(fs: sandbox, workspaceRoot: workspace.path);
      File(p.join(workspace.path, 'rel.txt')).writeAsStringSync('rel');
      final result = await tool.execute({'filePath': 'rel.txt'});
      expect(result.isError, isFalse, reason: result.content);
      expect(result.content, contains('1: rel'));
    });

    test('the bare filesystem configuration skips the boundary entirely',
        () async {
      final fs = MemoryFileSystem({'notes.md': 'alpha\n'});
      final tool = ReadTool(fs: fs);
      final result = await tool.execute({'filePath': 'notes.md'});
      expect(result.isError, isFalse, reason: result.content);
      expect(result.content, contains('1: alpha'));
    });
  });
}
