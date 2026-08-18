import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('StatTool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_stat_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('reports a file: type, size, permissions, mtime', () async {
      final f = File('${tmp.path}/a.txt')..writeAsStringSync('hello');
      final res = await StatTool().execute({'path': f.path});
      expect(res.isError, isFalse);
      expect(res.content, contains('type: file'));
      expect(res.content, contains('size: 5'));
      expect(res.content, contains('permissions: 06'));
      expect(res.content, contains('modified:'));
    });

    test('reports a directory', () async {
      final res = await StatTool().execute({'path': tmp.path});
      expect(res.isError, isFalse);
      expect(res.content, contains('type: directory'));
    });

    test('reports a symlink and its target', () async {
      final target = File('${tmp.path}/target.txt')..writeAsStringSync('x');
      final link = Link('${tmp.path}/link.txt')
        ..createSync(target.path);
      final res = await StatTool().execute({'path': link.path});
      expect(res.isError, isFalse);
      expect(res.content, contains('type: symlink'));
      expect(res.content, contains('target: ${target.path}'));
      expect(res.content, contains('resolves to: file'));
    });

    test('reports a broken link without throwing', () async {
      final link = Link('${tmp.path}/dangling.txt')
        ..createSync('${tmp.path}/gone.txt');
      final res = await StatTool().execute({'path': link.path});
      expect(res.isError, isFalse);
      expect(res.content, contains('type: symlink'));
      expect(res.content, contains('target: ${tmp.path}/gone.txt'));
      expect(res.content, contains('resolves to: (broken link)'));
    });

    test('errors on a non-existent path', () async {
      final res = await StatTool()
          .execute({'path': '${tmp.path}/no-such-file'});
      expect(res.isError, isTrue);
      expect(res.content, contains('path does not exist'));
    });

    test('sandbox violation becomes a clean error', () async {
      final tinaDir = Directory.systemTemp.createTempSync('tina_stat_tina_');
      addTearDown(() => tinaDir.deleteSync(recursive: true));
      final sandbox = SandboxedFileSystem(const IoFileSystem(),
          projectRoot: tmp.path, tinaDir: tinaDir);
      final outside = File('/tmp/tina_stat_outside_tmp.txt')
        ..writeAsStringSync('x');
      addTearDown(() => outside.deleteSync());
      final res =
          await StatTool(sandbox: sandbox).execute({'path': outside.path});
      expect(res.isError, isTrue);
      expect(res.content, contains('escapes the project root'));
    });
  });
}
