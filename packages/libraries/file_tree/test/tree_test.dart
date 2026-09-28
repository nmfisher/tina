import 'dart:convert';
import 'dart:io';
import 'package:file_tree/file_tree.dart';
import 'package:test/test.dart';

void main() {
  test('content changes affect only a leaf and its ancestors', () async {
    final files = {
      'docs/user/a.md': 'one',
      'docs/dev/b.md': 'two',
      'src/main.dart': 'three',
    };
    Future<Snapshot> snapshot({bool contents = true}) => scan(
      list: () async => files.keys,
      read: contents ? (p) async => utf8.encode(files[p]!) : null,
    );
    final before = await snapshot();
    files['docs/user/a.md'] = 'changed';
    final after = await snapshot();
    expect(diff(before, after), isEmpty);
    expect(diff(before, after, contents: true).map((c) => c.path), [
      '.',
      'docs',
      'docs/user',
      'docs/user/a.md',
    ]);
    expect(
      after.entries['docs/dev']!.content,
      before.entries['docs/dev']!.content,
    );
    final names = await snapshot(contents: false);
    expect(names.root.content, isNull);
    expect(() => diff(names, after, contents: true), throwsArgumentError);
  });

  test('names detect additions, removals, renames and empty root', () async {
    final before = await scan(list: () async => ['docs/a', 'src/b']);
    final after = await scan(list: () async => ['docs/c', 'src/b']);
    expect(diff(before, after).map((c) => '${c.path}:${c.kind.name}'), [
      '.:changed',
      'docs:changed',
      'docs/a:removed',
      'docs/c:added',
    ]);
    final empty = await scan(list: () async => []);
    expect(empty.root.children, isEmpty);
  });

  test(
    'scan rejects incomplete inventories, traversal, conflicts and limits',
    () async {
      await expectLater(
        scan(list: () async => throw StateError('truncated')),
        throwsStateError,
      );
      await expectLater(
        scan(list: () async => ['../secret']),
        throwsFormatException,
      );
      await expectLater(
        scan(list: () async => ['file', 'file/child']),
        throwsFormatException,
      );
      await expectLater(
        scan(list: () async => ['a', 'b'], maxFiles: 1),
        throwsStateError,
      );
      await expectLater(
        scan(list: () async => ['a/b/c'], maxDepth: 2),
        throwsStateError,
      );
    },
  );

  test('bounded reads reject links and changes during validation', () async {
    final dir = await Directory.systemTemp.createTemp('file-tree-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a');
    await file.writeAsString('abc');
    expect(await readFile(dir.path, 'a', maxBytes: 3), utf8.encode('abc'));
    expect(await readFile(dir.path, 'missing'), isNull);
    await expectLater(readFile(dir.path, 'a', maxBytes: 2), throwsStateError);
    await Link('${dir.path}/link').create(file.path);
    await expectLater(readFile(dir.path, 'link'), throwsStateError);
    var checks = 0;
    await expectLater(
      readFile(
        dir.path,
        'a',
        validate: (_) async {
          if (++checks == 2) throw StateError('permission changed');
        },
      ),
      throwsStateError,
    );
  });
}
