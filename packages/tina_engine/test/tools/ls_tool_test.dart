import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('LsTool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_ls_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('lists entries with type marker, directories first', () async {
      Directory('${tmp.path}/sub').createSync();
      File('${tmp.path}/a.txt').writeAsStringSync('hello');
      final res = await LsTool().execute({'path': tmp.path});
      expect(res.isError, isFalse);
      final subLine = res.content
          .split('\n')
          .firstWhere((l) => l.endsWith('sub'));
      expect(subLine, startsWith('d '));
      final fileLine = res.content
          .split('\n')
          .firstWhere((l) => l.endsWith('a.txt'));
      expect(fileLine, startsWith('- '));
      expect(fileLine, contains('5'));
      // Directories sort before files.
      expect(res.content.indexOf('sub'), lessThan(res.content.indexOf('a.txt')));
    });

    test('hides dot-entries unless all is true', () async {
      File('${tmp.path}/.hidden').writeAsStringSync('x');
      File('${tmp.path}/visible.txt').writeAsStringSync('x');
      final withoutAll = await LsTool().execute({'path': tmp.path});
      expect(withoutAll.content, contains('visible.txt'));
      expect(withoutAll.content, isNot(contains('.hidden')));
      final withAll =
          await LsTool().execute({'path': tmp.path, 'all': true});
      expect(withAll.content, contains('.hidden'));
    });

    test('(empty) for a directory with no visible entries', () async {
      File('${tmp.path}/.only-hidden').writeAsStringSync('x');
      final res = await LsTool().execute({'path': tmp.path});
      expect(res.content, equals('(empty)'));
    });

    test('respects maxResults with a "... more" marker', () async {
      for (var i = 0; i < 5; i++) {
        File('${tmp.path}/f$i.txt').writeAsStringSync('x');
      }
      final res = await LsTool()
          .execute({'path': tmp.path, 'maxResults': 2});
      expect(res.content, contains('f0.txt'));
      expect(res.content, contains('f1.txt'));
      expect(res.content, contains('3 more'));
    });

    test('errors on a non-existent path', () async {
      final res = await LsTool().execute({'path': '/no/such/dir-tina'});
      expect(res.isError, isTrue);
      expect(res.content, contains('path does not exist'));
    });

    test('errors on a path that is a file', () async {
      final f = File('${tmp.path}/plain.txt')..writeAsStringSync('x');
      final res = await LsTool().execute({'path': f.path});
      expect(res.isError, isTrue);
      expect(res.content, contains('not a directory'));
    });

    test('sandbox violation becomes a clean error', () async {
      final tinaDir = Directory.systemTemp.createTempSync('tina_ls_tina_');
      addTearDown(() => tinaDir.deleteSync(recursive: true));
      final sandbox = SandboxedFileSystem(const IoFileSystem(),
          projectRoot: tmp.path, tinaDir: tinaDir);
      final outside = Directory.systemTemp.createTempSync('tina_ls_out_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final res = await LsTool(sandbox: sandbox).execute({'path': outside.path});
      expect(res.isError, isTrue);
      expect(res.content, contains('escapes the project root'));
    });
  });
}
