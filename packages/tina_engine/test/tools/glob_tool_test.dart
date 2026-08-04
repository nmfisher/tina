import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_file_enumerator.dart';

void main() {
  // GlobTool is driven entirely by the injected FileEnumerator — no git, no
  // disk walk. A real temp dir is used only as the `path` value so the
  // existence pre-check passes; the enumerated file list is scripted.

  group('GlobTool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_glob_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('finds .dart files via **/*.dart from a scripted file list', () async {
      final fs = MemoryFileEnumerator({
        tmp.path: ['a.dart', 'b.txt', 'sub/c.dart'],
      });
      final res = await GlobTool(fileEnumerator: fs)
          .execute({'pattern': '**/*.dart', 'path': tmp.path});
      expect(res.isError, isFalse);
      expect(res.content, contains('a.dart'));
      expect(res.content, contains('sub/c.dart'));
      expect(res.content, isNot(contains('b.txt')));
    });

    test('respects maxResults with a "... more" marker', () async {
      final files = [for (var i = 0; i < 5; i++) 'f$i.dart'];
      final fs = MemoryFileEnumerator({tmp.path: files});
      final res = await GlobTool(fileEnumerator: fs).execute({
        'pattern': '*.dart',
        'path': tmp.path,
        'maxResults': 2,
      });
      expect(res.content, contains('f0.dart'));
      expect(res.content, contains('f1.dart'));
      expect(res.content, contains('3 more'));
    });

    test('(no matches) when nothing matches the pattern', () async {
      final fs = MemoryFileEnumerator({tmp.path: ['a.txt']});
      final res = await GlobTool(fileEnumerator: fs)
          .execute({'pattern': '*.dart', 'path': tmp.path});
      expect(res.content, equals('(no matches)'));
    });

    test('rejects an empty pattern', () async {
      final res = await GlobTool(fileEnumerator: MemoryFileEnumerator({}))
          .execute({'pattern': ''});
      expect(res.isError, isTrue);
      expect(res.content, contains('pattern is required'));
    });

    test('rejects a missing path', () async {
      final res = await GlobTool(fileEnumerator: MemoryFileEnumerator({}))
          .execute({'pattern': '*', 'path': '/no/such/dir-tina'});
      expect(res.isError, isTrue);
      expect(res.content, contains('path does not exist'));
    });
  });
}
