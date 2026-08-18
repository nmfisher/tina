import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('WhichTool', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_which_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    WhichTool toolWithBinDir() {
      final bin = Directory('${tmp.path}/bin')..createSync();
      final exe = File('${bin.path}/tina-fake-tool')
        ..writeAsStringSync('#!/bin/sh\n');
      // Make it executable (0o755).
      Process.runSync('chmod', ['755', exe.path]);
      return WhichTool(environment: {'PATH': bin.path});
    }

    test('resolves a name found on the injected PATH', () async {
      final tool = toolWithBinDir();
      final res = await tool.execute({'name': 'tina-fake-tool'});
      expect(res.isError, isFalse);
      expect(res.content, contains('tina-fake-tool'));
      expect(res.content, isNot(contains('not found')));
    });

    test('reports not found for a name missing from PATH', () async {
      final tool = toolWithBinDir();
      final res = await tool.execute({'name': 'definitely-not-on-path'});
      expect(res.isError, isFalse);
      expect(res.content, contains('not found: definitely-not-on-path'));
    });

    test('probes a comma-separated list in one call', () async {
      final tool = toolWithBinDir();
      final res =
          await tool.execute({'name': 'tina-fake-tool, no-such-binary'});
      expect(res.content, contains('tina-fake-tool'));
      expect(res.content, contains('not found: no-such-binary'));
    });

    test('checks a candidate containing a path separator directly',
        () async {
      final bin = Directory('${tmp.path}/bin')..createSync();
      final exe = File('${bin.path}/direct-tool')..writeAsStringSync('');
      Process.runSync('chmod', ['755', exe.path]);
      final tool = WhichTool(environment: const {'PATH': ''});
      final res = await tool.execute({'name': exe.path});
      expect(res.content, contains('direct-tool'));
      expect(res.content, isNot(contains('not found')));
    });

    test('a non-executable file on PATH is not resolved', () async {
      final bin = Directory('${tmp.path}/bin')..createSync();
      File('${bin.path}/plain-file').writeAsStringSync('no exec bit');
      final tool = WhichTool(environment: {'PATH': bin.path});
      final res = await tool.execute({'name': 'plain-file'});
      expect(res.content, contains('not found: plain-file'));
    });

    test('rejects an empty name', () async {
      final res = await WhichTool(environment: const {}).execute({'name': ''});
      expect(res.isError, isTrue);
      expect(res.content, contains('name is required'));
    });
  });
}
