import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tui/src/config_document.dart';

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
}
