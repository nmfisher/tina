import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('previewToolCall', () {
    test('bash and read return no preview', () async {
      expect(
        await previewToolCall('bash', {'command': 'ls'}),
        isEmpty,
      );
      expect(
        await previewToolCall('read', {'filePath': '/tmp/x'}),
        isEmpty,
      );
    });

    test('edit shows a header + removed + added lines', () async {
      final p = await previewToolCall('edit', {
        'filePath': '/tmp/foo.dart',
        'oldString': 'final x = 1;\nfinal y = 2;',
        'newString': 'final x = 10;\nfinal y = 20;',
      });
      expect(p.first, isA<PreviewHeader>());
      expect((p.first as PreviewHeader).text, contains('edit: /tmp/foo.dart'));
      final removed = p.whereType<PreviewRemoved>().map((e) => e.text).toList();
      final added = p.whereType<PreviewAdded>().map((e) => e.text).toList();
      expect(removed, ['final x = 1;', 'final y = 2;']);
      expect(added, ['final x = 10;', 'final y = 20;']);
    });

    test('edit replaceAll annotates header', () async {
      final p = await previewToolCall('edit', {
        'filePath': '/tmp/foo.dart',
        'oldString': 'a',
        'newString': 'b',
        'replaceAll': true,
      });
      expect((p.first as PreviewHeader).text, contains('(replaceAll)'));
    });

    test('write of a new file shows header + first lines', () async {
      final tmp = Directory.systemTemp.createTempSync('tina_preview_');
      try {
        final p = await previewToolCall('write', {
          'filePath': '${tmp.path}/new.txt',
          'content': 'one\ntwo\nthree\n',
        });
        expect((p.first as PreviewHeader).text, contains('new file'));
        final added = p.whereType<PreviewAdded>().map((e) => e.text).toList();
        expect(added, ['one', 'two', 'three']);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('write that overwrites computes a diff with hunks', () async {
      final tmp = Directory.systemTemp.createTempSync('tina_preview_');
      try {
        final file = File('${tmp.path}/x.txt')
          ..writeAsStringSync('a\nb\nc\nd\ne\nf\n');
        final p = await previewToolCall('write', {
          'filePath': file.path,
          'content': 'a\nb\nC\nd\ne\nF\n',
        });
        expect((p.first as PreviewHeader).text, contains('overwrite'));
        final removed = p.whereType<PreviewRemoved>().map((e) => e.text).toSet();
        final added = p.whereType<PreviewAdded>().map((e) => e.text).toSet();
        expect(removed, containsAll(<String>['c', 'f']));
        expect(added, containsAll(<String>['C', 'F']));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('write with identical content reports no change', () async {
      final tmp = Directory.systemTemp.createTempSync('tina_preview_');
      try {
        final file = File('${tmp.path}/same.txt')..writeAsStringSync('same\n');
        final p = await previewToolCall('write', {
          'filePath': file.path,
          'content': 'same\n',
        });
        expect(p, hasLength(1));
        expect((p.first as PreviewHeader).text, contains('no change'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('preview is clipped past the line cap', () async {
      final big = List.generate(200, (i) => 'line $i').join('\n');
      final p = await previewToolCall('edit', {
        'filePath': '/tmp/big.txt',
        'oldString': big,
        'newString': 'one\n',
      });
      // Header + bounded removed lines + truncation marker + added line(s).
      // The exact count depends on the cap but it must NOT be 200+.
      expect(p.length, lessThan(80));
      expect(p.whereType<PreviewContext>().map((e) => e.text),
          anyElement(contains('more')));
    });
  });
}
