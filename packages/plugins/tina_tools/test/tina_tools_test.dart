import 'dart:io';

import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('sandboxed file system', () {
    late Directory tmp;
    late Directory tina;
    late FileSystem io;
    late SandboxedFileSystem sandbox;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_tools_sandbox_');
      tina = Directory('${Directory.systemTemp.path}/tina_tools_tina_home');
      io = const IoFileSystem();
      sandbox = SandboxedFileSystem(io,
          workspaceRoot: tmp.path,
          tinaDir: tina,
          mode: PermissionMode.allowEdits);
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('allows a write inside the root (parent made by the caller)',
        () async {
      final dir = p.join(tmp.path, 'newdir');
      await sandbox.createDirectory(dir, recursive: true);
      final target = p.join(dir, 'file.txt');
      await sandbox.writeFile(target, 'hello');
      expect(File(target).readAsStringSync(), 'hello');
    });

    test('refuses ../ that climbs out of the root', () async {
      expect(
        () => sandbox.writeFile(p.join(tmp.path, '..', 'escape.txt'), 'x'),
        throwsA(isA<SandboxViolation>()),
      );
    });

    test('refuses an absolute path outside the root', () async {
      expect(
        () => sandbox.writeFile('/etc/passwd', 'x'),
        throwsA(isA<SandboxViolation>()),
      );
    });

    test('a read outside the root lands — reads anywhere but the tina tree',
        () async {
      final outside = Directory.systemTemp.createTempSync('tina_tools_out_');
      addTearDown(() => outside.deleteSync(recursive: true));
      File(p.join(outside.path, 'secret.txt')).writeAsStringSync('s');
      // Reads anywhere the process can reach are allowed in both modes.
      for (final m in PermissionMode.values) {
        sandbox.mode = m;
        expect(await sandbox.readFileString(p.join(outside.path, 'secret.txt')),
            's',
            reason: '$m');
      }
      sandbox.mode = PermissionMode.ask;
    });

    test('a read inside the project lands in both modes', () async {
      File(p.join(tmp.path, 'in.txt')).writeAsStringSync('in');
      for (final m in PermissionMode.values) {
        sandbox.mode = m;
        expect(await sandbox.readFileString(p.join(tmp.path, 'in.txt')), 'in',
            reason: '$m');
      }
      sandbox.mode = PermissionMode.ask;
    });

    test('a write outside the project asks: no denies, yes runs', () async {
      final outside = Directory.systemTemp.createTempSync('tina_tools_ask_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final target = p.join(outside.resolveSymbolicLinksSync(), 'out.txt');

      var answers = <Approval>[Approval.no];
      var asked = 0;
      final asking = SandboxedFileSystem(io,
          workspaceRoot: tmp.path, tinaDir: tina, approver: (request, _) async {
        asked++;
        expect(request.op, FileOp.write);
        expect(request.path, target);
        return answers.removeAt(0);
      });

      // Approver says no → refused, reason says what was asked.
      await expectLater(
        asking.writeFile(target, 'v1'),
        throwsA(isA<SandboxViolation>().having(
            (e) => e.message, 'message', contains('allow write outside'))),
      );
      expect(asked, 1);
      expect(File(target).existsSync(), isFalse);

      // Approver says yes → the write runs.
      answers = [Approval.yes];
      await asking.writeFile(target, 'v2');
      expect(asked, 2);
      expect(File(target).readAsStringSync(), 'v2');
    });

    test(
        'an "always" answer remembers the grant — the second write does not ask',
        () async {
      final outside = Directory.systemTemp.createTempSync('tina_tools_gr_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final target = p.join(outside.path, 'out.txt');
      var asked = 0;
      final asking = SandboxedFileSystem(io,
          workspaceRoot: tmp.path, tinaDir: tina, approver: (_, __) async {
        asked++;
        return Approval.always;
      });

      await asking.writeFile(target, 'v1');
      await asking.writeFile(target, 'v2');
      expect(asked, 1, reason: 'the second identical write skips the approver');
      expect(File(target).readAsStringSync(), 'v2');
    });

    test('refuses a write into ~/.tina', () async {
      expect(
        () => sandbox.writeFile(p.join(tina.path, 'x.txt'), 'x'),
        throwsA(isA<SandboxViolation>()),
      );
    });

    test('denies ~/.tina before it exists (walk-up resolves home)', () async {
      expect(tina.existsSync(), isFalse,
          reason: 'precondition: the data tree was never created');
      expect(
        () => sandbox.writeFile(p.join(tina.path, 'x.txt'), 'x'),
        throwsA(isA<SandboxViolation>()),
      );
      expect(tina.existsSync(), isFalse,
          reason: 'the refused write must not have created the tree');
    });

    test('delete/rename/createDirectory are confined too', () async {
      File(p.join(tmp.path, 'f.txt')).writeAsStringSync('x');
      // Outside-root targets are asked about; nothing wired → refuse.
      expect(() => sandbox.delete('/etc/passwd'),
          throwsA(isA<SandboxViolation>()));
      expect(
          () => sandbox.rename(
              p.join(tmp.path, 'f.txt'), p.join(tmp.path, '..', 'g.txt')),
          throwsA(isA<SandboxViolation>()));
      expect(() => sandbox.createDirectory(p.join(tina.path, 'sidecar')),
          throwsA(isA<SandboxViolation>()));
      expect(File('/etc/passwd').existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'g.txt')).existsSync(), isFalse);
    });
  });

  group('ls tool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_tools_ls_');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('happy path: markers, sizes, directories first, hidden filtering',
        () async {
      Directory('${tmp.path}/sub').createSync();
      File('${tmp.path}/a.txt').writeAsStringSync('hello');
      File('${tmp.path}/.hidden').writeAsStringSync('x');

      final res = await LsTool(workspaceRoot: tmp.path).execute({'path': '.'});
      expect(res.isError, isFalse);
      expect(res.content, isNot(contains('.hidden')));
      final subLine =
          res.content.split('\n').firstWhere((l) => l.endsWith('sub'));
      expect(subLine, startsWith('d '));
      final fileLine =
          res.content.split('\n').firstWhere((l) => l.endsWith('a.txt'));
      expect(fileLine, startsWith('- '));
      expect(fileLine, contains('5'));
      expect(
          res.content.indexOf('sub'), lessThan(res.content.indexOf('a.txt')));

      final all = await LsTool(workspaceRoot: tmp.path)
          .execute({'path': '.', 'all': true});
      expect(all.content, contains('.hidden'));
    });

    test('(empty) for nothing visible, maxResults truncation, error paths',
        () async {
      final none = await LsTool(workspaceRoot: tmp.path).execute({'path': '.'});
      expect(none.content, equals('(empty)'));

      for (var i = 0; i < 5; i++) {
        File('${tmp.path}/f$i.txt').writeAsStringSync('x');
      }
      final res = await LsTool(workspaceRoot: tmp.path)
          .execute({'path': '.', 'maxResults': 2});
      expect(res.content, contains('f0.txt'));
      expect(res.content, contains('3 more'));

      final missing = await LsTool(workspaceRoot: tmp.path)
          .execute({'path': 'no/such/dir'});
      expect(missing.isError, isTrue);
      expect(missing.content, contains('path does not exist'));

      File('${tmp.path}/plain.txt').writeAsStringSync('x');
      final notDir =
          await LsTool(workspaceRoot: tmp.path).execute({'path': 'plain.txt'});
      expect(notDir.isError, isTrue);
      expect(notDir.content, contains('not a directory'));
    });

    test('reads are allowed anywhere; a refusal names the reason', () async {
      final outside = Directory.systemTemp.createTempSync('tina_tools_lso_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final sandbox = SandboxedFileSystem(const IoFileSystem(),
          workspaceRoot: tmp.path,
          tinaDir:
              Directory('${Directory.systemTemp.path}/tina_tools_tina_home'));
      // Reads anywhere (both modes) — the guard lets it through.
      final res = await LsTool(workspaceRoot: tmp.path, sandbox: sandbox)
          .execute({'path': outside.path});
      expect(res.isError, isFalse);

      // Only the Tina data tree is refused, and the refusal is explicit.
      final tinaDir =
          Directory('${Directory.systemTemp.path}/tina_tools_tina_home')
            ..createSync(recursive: true);
      addTearDown(() => tinaDir.deleteSync(recursive: true));
      final denied = await LsTool(workspaceRoot: tmp.path, sandbox: sandbox)
          .execute({'path': tinaDir.path});
      expect(denied.isError, isTrue);
      expect(
          denied.content, contains('Access to the Tina data tree is blocked'));
    });
  });

  group('read tool', () {
    test('happy path against the memory filesystem', () async {
      final fs = MemoryFileSystem({'notes.md': 'alpha\nbeta\ngamma\n'});
      final res = await ReadTool(fs: fs).execute({'filePath': 'notes.md'});
      expect(res.isError, isFalse);
      expect(res.content, contains('1: alpha'));
      expect(res.content, contains('3: gamma'));

      final window = await ReadTool(fs: fs)
          .execute({'filePath': 'notes.md', 'offset': 2, 'limit': 1});
      expect(window.content, contains('2: beta'));
      expect(window.content, isNot(contains('alpha')));

      final missing = await ReadTool(fs: fs).execute({'filePath': 'nope.md'});
      expect(missing.isError, isTrue);
      expect(missing.content, contains('File not found'));

      final binary = MemoryFileSystem()..addBinaryFile('b.bin', [0, 1, 2]);
      final bin = await ReadTool(fs: binary).execute({'filePath': 'b.bin'});
      expect(bin.isError, isTrue);
      expect(bin.content, contains('binary'));

      final noArg = await ReadTool(fs: MemoryFileSystem()).execute({});
      expect(noArg.isError, isTrue);
      expect(noArg.content, contains('filePath is required'));
    });

    test('refusal reaches the tool result and names the reason', () async {
      final tmp = Directory.systemTemp.createTempSync('tina_tools_read_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final tinaDir =
          Directory('${Directory.systemTemp.path}/tina_tools_tina_home')
            ..createSync(recursive: true);
      addTearDown(() => tinaDir.deleteSync(recursive: true));
      final sandbox = SandboxedFileSystem(
        const IoFileSystem(),
        workspaceRoot: tmp.path,
        tinaDir: tinaDir,
      );
      // A read the guard refuses (the Tina data tree) → error result.
      final res = await ReadTool(fs: sandbox, workspaceRoot: tmp.path)
          .execute({'filePath': p.join(tinaDir.path, 'session.json')});
      expect(res.isError, isTrue);
      expect(res.content, contains('Access to the Tina data tree is blocked'));
    });
  });

  group('write tool', () {
    test('create and overwrite against the memory filesystem', () async {
      final fs = MemoryFileSystem();
      final tool = WriteTool(fs: fs);
      final created =
          await tool.execute({'filePath': 'deep/dir/new.txt', 'content': 'v1'});
      expect(created.isError, isFalse);
      expect(created.content, startsWith('created'));
      expect(fs.files['deep/dir/new.txt'], 'v1');

      final overwrote =
          await tool.execute({'filePath': 'deep/dir/new.txt', 'content': 'v2'});
      expect(overwrote.content, startsWith('overwrote'));
      expect(fs.files['deep/dir/new.txt'], 'v2');

      final noContent = await tool.execute({'filePath': 'deep/dir/new.txt'});
      expect(noContent.isError, isTrue);
      expect(noContent.content, contains('content is required'));
    });

    test('readOnly denies an in-project write; nothing asks', () async {
      final tmp = Directory.systemTemp.createTempSync('tina_tools_write_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      var asked = 0;
      final sandbox = SandboxedFileSystem(
        const IoFileSystem(),
        workspaceRoot: tmp.path,
        tinaDir: Directory('${Directory.systemTemp.path}/tina_tools_tina_home'),
        mode: PermissionMode.readOnly,
        approver: (_, __) async {
          asked++;
          return Approval.yes;
        },
      );
      final res = await WriteTool(fs: sandbox, workspaceRoot: tmp.path)
          .execute({'filePath': 'in-project.txt', 'content': 'x'});
      expect(res.isError, isTrue);
      expect(res.content, contains('read-only mode'));
      expect(asked, 0);
    });

    test('no tool carries a declaration — the same WriteTool in both modes',
        () async {
      final tmp = Directory.systemTemp.createTempSync('tina_tools_decl_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final tinaDir =
          Directory('${Directory.systemTemp.path}/tina_tools_tina_home');

      // One WriteTool, nothing capability-shaped set on it, is fine.
      final tool = WriteTool(
          fs: SandboxedFileSystem(const IoFileSystem(),
              workspaceRoot: tmp.path,
              tinaDir: tinaDir,
              mode: PermissionMode.allowEdits),
          workspaceRoot: tmp.path);

      final normal = await tool.execute({'filePath': 'a.txt', 'content': 'n'});
      expect(normal.isError, isFalse);
      expect(File(p.join(tmp.path, 'a.txt')).readAsStringSync(), 'n');

      // The very same instance flips with the filesystem's mode.
      (tool.fs as SandboxedFileSystem).mode = PermissionMode.readOnly;
      final readOnly =
          await tool.execute({'filePath': 'b.txt', 'content': 'r'});
      expect(readOnly.isError, isTrue);
      expect(readOnly.content, contains('read-only mode'));
      expect(File(p.join(tmp.path, 'b.txt')).existsSync(), isFalse);
    });
  });

  group('edit tool', () {
    test('unique replace, replaceAll, and conflict shapes on memory', () async {
      final fs = MemoryFileSystem({'code.txt': 'one two one\nthree one\n'});
      final tool = EditTool(fs: fs);

      final ambiguous = await tool.execute({
        'filePath': 'code.txt',
        'oldString': 'one',
        'newString': '1',
      });
      expect(ambiguous.isError, isTrue);
      expect(ambiguous.content, contains('edit_conflict'));
      expect(ambiguous.content, contains('ambiguousMatch'));

      final ok = await tool.execute({
        'filePath': 'code.txt',
        'oldString': 'one two',
        'newString': '1 2',
      });
      expect(ok.isError, isFalse);
      expect(ok.content, contains('1 replacement'));
      expect(fs.files['code.txt'], '1 2 one\nthree one\n');

      final all = await tool.execute({
        'filePath': 'code.txt',
        'oldString': 'one',
        'newString': 'ONE',
        'replaceAll': true,
      });
      expect(all.content, contains('2 replacements'));
      expect(fs.files['code.txt'], '1 2 ONE\nthree ONE\n');

      final missing = await tool.execute({
        'filePath': 'code.txt',
        'oldString': 'zzz',
        'newString': 'y',
      });
      expect(missing.isError, isTrue);
      expect(missing.content, contains('missingMatch'));

      final identical = await tool.execute({
        'filePath': 'code.txt',
        'oldString': 'x',
        'newString': 'x',
      });
      expect(identical.isError, isTrue);
      expect(identical.content, contains('identical'));
    });

    test('a write outside the project asks; no approver wired → denied',
        () async {
      final tmp = Directory.systemTemp.createTempSync('tina_tools_edit_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final sandbox = SandboxedFileSystem(
        const IoFileSystem(),
        workspaceRoot: tmp.path,
        tinaDir: Directory('${Directory.systemTemp.path}/tina_tools_tina_home'),
      );
      final res = await EditTool(fs: sandbox, workspaceRoot: tmp.path).execute({
        'filePath': p.join(Directory.systemTemp.path, 'victim.txt'),
        'oldString': 'a',
        'newString': 'b',
      });
      expect(res.isError, isTrue);
      expect(res.content, contains('no approver is wired'));
    });
  });

  group('glob tool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_tools_glob_');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('happy path: pattern, ** matching, no-match text', () async {
      Directory('${tmp.path}/lib/src').createSync(recursive: true);
      File('${tmp.path}/lib/a.dart').writeAsStringSync('');
      File('${tmp.path}/lib/src/b.dart').writeAsStringSync('');
      File('${tmp.path}/README.md').writeAsStringSync('');

      final tool = GlobTool(workspaceRoot: tmp.path);

      final dart = await tool.execute({'pattern': '**/*.dart'});
      expect(dart.isError, isFalse);
      expect(dart.content, contains('lib/a.dart'));
      expect(dart.content, contains('lib/src/b.dart'));
      expect(dart.content, isNot(contains('README.md')));

      final top = await tool.execute({'pattern': '*.md'});
      expect(top.content, contains('README.md'));

      final none = await tool.execute({'pattern': '*.rs'});
      expect(none.content, equals('(no matches)'));
    });

    test('a read outside the project is allowed in both modes', () async {
      final outside = Directory.systemTemp.createTempSync('tina_tools_glo_');
      addTearDown(() => outside.deleteSync(recursive: true));
      File('${outside.path}/x.dart').writeAsStringSync('');
      final sandbox = SandboxedFileSystem(const IoFileSystem(),
          workspaceRoot: tmp.path,
          tinaDir:
              Directory('${Directory.systemTemp.path}/tina_tools_tina_home'));
      for (final m in PermissionMode.values) {
        sandbox.mode = m;
        final res = await GlobTool(workspaceRoot: tmp.path, sandbox: sandbox)
            .execute({'pattern': '*.dart', 'path': outside.path});
        expect(res.isError, isFalse, reason: '$m');
        expect(res.content, contains('x.dart'));
      }
      sandbox.mode = PermissionMode.ask;
    });
  });

  group('stat tool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_tools_stat_');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('happy path: file, directory, symlink target', () async {
      Directory('${tmp.path}/sub').createSync();
      final f = File('${tmp.path}/a.txt')..writeAsStringSync('hello');
      Link('${tmp.path}/lnk').createSync(f.path);

      final tool = StatTool(workspaceRoot: tmp.path);

      final fileRes = await tool.execute({'path': 'a.txt'});
      expect(fileRes.isError, isFalse);
      expect(fileRes.content, contains('type: file'));
      expect(fileRes.content, contains('size: 5'));

      final dirRes = await tool.execute({'path': 'sub'});
      expect(dirRes.content, contains('type: directory'));

      final linkRes = await tool.execute({'path': 'lnk'});
      expect(linkRes.content, contains('type: symlink'));
      expect(linkRes.content, contains('target: ${f.path}'));

      final missing = await tool.execute({'path': 'nope'});
      expect(missing.isError, isTrue);
      expect(missing.content, contains('path does not exist'));
    });

    test('a refusal names the reason and flags the result as an error',
        () async {
      final tinaDir =
          Directory('${Directory.systemTemp.path}/tina_tools_tina_home')
            ..createSync(recursive: true);
      addTearDown(() => tinaDir.deleteSync(recursive: true));
      final sandbox = SandboxedFileSystem(const IoFileSystem(),
          workspaceRoot: tmp.path, tinaDir: tinaDir);
      final res = await StatTool(workspaceRoot: tmp.path, sandbox: sandbox)
          .execute({'path': p.join(tinaDir.path, 'session.json')});
      expect(res.isError, isTrue);
      expect(res.content, contains('Access to the Tina data tree is blocked'));
    });
  });
}
