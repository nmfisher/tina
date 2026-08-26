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

    test('launch_workflow shows the workflow name and the task', () async {
      final p = await previewToolCall('launch_workflow', {
        'input': 'add a settings screen to the CLI',
        'workflow': 'lint',
      });
      expect(p, hasLength(1));
      expect((p.first as PreviewHeader).text,
          'workflow "lint" — add a settings screen to the CLI');
    });

    test('launch_workflow defaults the workflow name to "default"', () async {
      final p = await previewToolCall('launch_workflow', {
        'input': 'fix the bug',
      });
      expect((p.first as PreviewHeader).text,
          contains('workflow "default"'));
      expect((p.first as PreviewHeader).text, contains('fix the bug'));
    });

    test('launch_workflow shows the first task line and counts the rest',
        () async {
      final p = await previewToolCall('launch_workflow', {
        'input': 'refactor the auth module\nsplit it in two\nadd tests',
      });
      expect((p.first as PreviewHeader).text,
          contains('workflow "default" — refactor the auth module'));
      expect(p.whereType<PreviewContext>().map((e) => e.text),
          anyElement(contains('2 more lines')));
    });

    test('launch_workflow with an empty task shows just the workflow',
        () async {
      final p = await previewToolCall('launch_workflow', {'input': '   '});
      expect((p.first as PreviewHeader).text, 'workflow "default"');
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

    test('edit whose oldString alone exceeds the cap still shows the addition',
        () async {
      // The filed failure mode: ~60 removals rendered, zero additions, no
      // marker — an approval whose operative half was invisible.
      final big = List.generate(70, (i) => 'old $i').join('\n');
      final p = await previewToolCall('edit', {
        'filePath': '/tmp/big.txt',
        'oldString': big,
        'newString': 'the single replacement',
      });
      expect(p.whereType<PreviewAdded>().map((e) => e.text),
          ['the single replacement'],
          reason: 'removals filling the cap must not starve the added side');
      expect(p.whereType<PreviewContext>().map((e) => e.text),
          anyElement(contains('more removed')),
          reason: 'a clipped side is named, never silently elided');
    });

    test('both sides render their half of the cap, markers name each',
        () async {
      final oldBig = List.generate(100, (i) => 'old $i').join('\n');
      final newBig = List.generate(100, (i) => 'new $i').join('\n');
      final p = await previewToolCall('edit', {
        'filePath': '/tmp/big.txt',
        'oldString': oldBig,
        'newString': newBig,
      });
      expect(p.whereType<PreviewRemoved>(), hasLength(30),
          reason: 'half of the 60-line cap');
      expect(p.whereType<PreviewAdded>(), hasLength(30));
      expect(
        p.whereType<PreviewContext>().map((e) => e.text).toList(),
        ['… (-70 more removed)', '… (+70 more added)'],
      );
    });
  });
}
