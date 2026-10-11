import 'dart:async';
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

  group('operation approval stays scoped to its target and lifetime', () {
    test('changing a symlink during approval cannot authorize its new target',
        () async {
      final approved = Directory(p.join(root.path, 'approved'))..createSync();
      final refused = Directory(p.join(root.path, 'refused'))..createSync();
      final victim = File(p.join(refused.path, 'note.txt'))
        ..writeAsStringSync('original');
      final alias = Link(p.join(workspace.path, 'alias'))
        ..createSync(approved.path);
      final approvedPath =
          p.join(approved.resolveSymbolicLinksSync(), 'note.txt');
      sandbox.approver = (request, reason) async {
        if (request.path != approvedPath) return Approval.no;
        alias.updateSync(refused.path);
        return Approval.yes;
      };

      final tool = WriteTool(fs: sandbox, workspaceRoot: workspace.path);
      final result = await tool.execute({
        'filePath': p.join(alias.path, 'note.txt'),
        'content': 'unauthorized change',
      });
      expect(result.isError, isTrue);
      expect(victim.readAsStringSync(), 'original');
    });

    test('nested approval does not replace the enclosing approval', () async {
      final path = p.join(root.path, 'nested.txt');
      await sandbox.authorizeOperation(FileOp.write, path, () async {
        await sandbox.authorizeOperation(FileOp.write, path, () async {
          await sandbox.writeFile(path, 'nested');
        });
        sandbox.approver = (request, reason) async => Approval.no;
        await sandbox.writeFile(path, 'outer');
      });
      expect(File(path).readAsStringSync(), 'outer');
      expect(spy.calls, 1);
    });

    test('a failed nested operation cannot leave its approval behind',
        () async {
      final outer = p.join(root.path, 'outer.txt');
      final inner = p.join(root.path, 'inner.txt');
      await sandbox.authorizeOperation(FileOp.write, outer, () async {
        await expectLater(
            sandbox.authorizeOperation(FileOp.write, inner, () async {
              throw StateError('failed operation');
            }),
            throwsStateError);
        sandbox.approver = (request, reason) async => Approval.no;
        await expectLater(sandbox.writeFile(inner, 'unauthorized'),
            throwsA(isA<SandboxViolation>()));
      });
      expect(File(inner).existsSync(), isFalse);
    });

    test('concurrent nested operations cannot use each other\'s approval',
        () async {
      final path = p.join(root.path, 'concurrent.txt');
      final entered = Completer<void>();
      final finish = Completer<void>();
      await sandbox.authorizeOperation(
          FileOp.write, p.join(root.path, 'outer.txt'), () async {
        final pending =
            sandbox.authorizeOperation(FileOp.write, path, () async {
          entered.complete();
          await finish.future;
        });
        await entered.future;
        sandbox.approver = (request, reason) async => Approval.no;
        try {
          await expectLater(sandbox.writeFile(path, 'unauthorized'),
              throwsA(isA<SandboxViolation>()));
        } finally {
          finish.complete();
          await pending;
        }
      });
      expect(File(path).existsSync(), isFalse);
    });

    for (final fails in [false, true]) {
      test(
          'detached async work loses approval after ${fails ? 'failure' : 'success'}',
          () async {
        final path = p.join(root.path, 'detached.txt');
        final resume = Completer<void>();
        late Future<void> detached;
        final operation =
            sandbox.authorizeOperation(FileOp.write, path, () async {
          detached = () async {
            await resume.future;
            await sandbox.writeFile(path, 'unauthorized');
          }();
          if (fails) throw StateError('failed operation');
        });
        if (fails) {
          await expectLater(operation, throwsStateError);
        } else {
          await operation;
        }
        sandbox.approver = (request, reason) async => Approval.no;
        final denied = expectLater(detached, throwsA(isA<SandboxViolation>()));
        resume.complete();
        await denied;
        expect(File(path).existsSync(), isFalse);
      });
    }

    test('a nested operation cannot extend an inherited approval', () async {
      final path = p.join(root.path, 'inherited.txt');
      final entered = Completer<void>();
      final resume = Completer<void>();
      late Future<void> nested;
      await sandbox.authorizeOperation(FileOp.write, path, () async {
        nested = sandbox.authorizeOperation(FileOp.write, path, () async {
          entered.complete();
          await resume.future;
          await sandbox.writeFile(path, 'unauthorized');
        });
        await entered.future;
      });
      sandbox.approver = (request, reason) async => Approval.no;
      final denied = expectLater(nested, throwsA(isA<SandboxViolation>()));
      resume.complete();
      await denied;
      expect(File(path).existsSync(), isFalse);
    });

    test('an approval belongs to one filesystem boundary', () async {
      final path = p.join(root.path, 'separate-boundary.txt');
      final other = SandboxedFileSystem(const IoFileSystem(),
          workspaceRoot: workspace.path,
          tinaDir: tinaDir,
          approver: (request, reason) async => Approval.no);
      await sandbox.authorizeOperation(FileOp.write, path, () async {
        await expectLater(other.writeFile(path, 'unauthorized'),
            throwsA(isA<SandboxViolation>()));
      });
      expect(File(path).existsSync(), isFalse);
    });
  });

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
