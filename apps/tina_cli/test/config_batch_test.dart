import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/src/config_document.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('tina-config-batch-'));
  tearDown(() => root.deleteSync(recursive: true));

  for (final exists in [false, true]) {
    test('batch restores first file when second save fails ($exists)', () {
      final first = File('${root.path}/global');
      const original = '# preserve exact formatting\n[plugins]\nenabled=[]\n';
      if (exists) first.writeAsStringSync(original);
      final document = exists
          ? ConfigDocument.open(first.path)
          : ConfigDocument.empty(first.path);
      document.table('plugins')['overrides'] = {'tina/goals': true};
      final obstacle = File('${root.path}/not-a-directory')
        ..writeAsStringSync('untouched');
      final second = ConfigDocument.empty('${obstacle.path}/config');
      second.table('plugins')['overrides'] = {'tina/goals': true};
      expect(() => ConfigDocument.saveScopedBatch([document, second]),
          throwsA(isA<FileSystemException>()));
      expect(first.existsSync(), exists);
      if (exists) expect(first.readAsStringSync(), original);
      expect(obstacle.readAsStringSync(), 'untouched');
    });
  }
  test('stale second file rejects the whole batch before the first save', () {
    final first = File('${root.path}/global')
      ..writeAsStringSync('[plugins]\nenabled=[]\n');
    final second = File('${root.path}/workspace')
      ..writeAsStringSync('[plugins.overrides]\n');
    final documents = [
      ConfigDocument.open(first.path),
      ConfigDocument.open(second.path)
    ];
    final original = first.readAsStringSync();
    for (final document in documents) {
      document.table('plugins')['overrides'] = {'tina/goals': true};
    }
    second.writeAsStringSync('# external change\n');
    expect(() => ConfigDocument.saveScopedBatch(documents), throwsStateError);
    expect(first.readAsStringSync(), original);
    expect(second.readAsStringSync(), '# external change\n');
  });

  test('one of two same-baseline writers wins, the other is rejected', () {
    final file = File('${root.path}/global')
      ..writeAsStringSync('[plugins]\nenabled=[]\n');
    final first = ConfigDocument.open(file.path);
    final second = ConfigDocument.open(file.path);
    first.table('plugins')['overrides'] = {'tina/goals': true};
    second.values['providers'] = {
      'local': {'model': 'm'}
    };
    first.saveScoped();
    // second's baseline predates first's save: the lock orders the
    // attempts, and the check inside it rejects the stale draft instead
    // of silently overwriting first's write.
    expect(() => second.saveScoped(), throwsStateError);
    expect(file.readAsStringSync(), contains('tina/goals'));
    expect(file.readAsStringSync(), isNot(contains('local')));
  });

  test('a writer re-opened after the competing save lands cleanly', () {
    final file = File('${root.path}/global')
      ..writeAsStringSync('[plugins]\nenabled=[]\n');
    final first = ConfigDocument.open(file.path);
    first.table('plugins')['overrides'] = {'tina/goals': true};
    first.saveScoped();
    // The reopen-settings flow: the new snapshot includes first's write,
    // so an edit to a different key composes with it.
    final second = ConfigDocument.open(file.path);
    second.values['providers'] = {
      'local': {'model': 'm'}
    };
    second.saveScoped();
    expect(file.readAsStringSync(), contains('tina/goals'));
    expect(file.readAsStringSync(), contains('local'));
  });

  test('nested batch write on the same file does not deadlock', () {
    final file = File('${root.path}/global')
      ..writeAsStringSync('[plugins]\nenabled=[]\n');
    final document = ConfigDocument.open(file.path);
    document.table('plugins')['overrides'] = {'tina/goals': true};
    // saveScopedBatch holds the file's lock for the whole commit while
    // each member's _write re-enters it.
    ConfigDocument.saveScopedBatch([document]);
    expect(file.readAsStringSync(), contains('tina/goals'));
  });

  test('batch locks targets in sorted order across two files', () {
    final global = File('${root.path}/global')
      ..writeAsStringSync('[plugins]\nenabled=[]\n');
    final workspace = File('${root.path}/workspace')
      ..writeAsStringSync('[plugins.overrides]\n');
    final documents = [
      ConfigDocument.open(workspace.path),
      ConfigDocument.open(global.path)
    ];
    for (final document in documents) {
      document.table('plugins')['overrides'] = {'tina/goals': true};
    }
    ConfigDocument.saveScopedBatch(documents);
    expect(global.readAsStringSync(), contains('tina/goals'));
    expect(workspace.readAsStringSync(), contains('tina/goals'));
  });
}
