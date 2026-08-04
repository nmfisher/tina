import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tina_index/walker.dart';

String get repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

void main() {
  group('DartFileWalker', () {
    test('finds .dart files in tina repo', () async {
      final walker = DartFileWalker(repoRoot: repoRoot);
      final files = await walker.walk();
      expect(files, isNotEmpty);
      expect(files, contains('lib/agent/agent.dart'));
      expect(files, contains('lib/llm/provider.dart'));
      expect(files.every((f) => f.endsWith('.dart')), isTrue);
    });

    test('excludes .dart_tool and build directories', () async {
      final walker = DartFileWalker(repoRoot: repoRoot);
      final files = await walker.walk();
      expect(files, isNot(anyElement(contains('.dart_tool'))));
      expect(files, isNot(anyElement(contains('build/'))));
    });
  });
}
