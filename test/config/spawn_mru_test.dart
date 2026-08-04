import 'dart:io';

import 'package:tina/config/spawn_mru.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tina_spawn_mru_test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('load is empty when no MRU file exists', () {
    expect(loadSpawnMru(env: {}, tinaDir: tmp), isEmpty);
  });

  test('record then load returns the ref, most-recent first', () {
    recordSpawnMru('alpha/a1', env: {}, tinaDir: tmp);
    recordSpawnMru('beta/b1', env: {}, tinaDir: tmp);
    recordSpawnMru('alpha/a2', env: {}, tinaDir: tmp);
    expect(loadSpawnMru(env: {}, tinaDir: tmp),
        ['alpha/a2', 'beta/b1', 'alpha/a1']);
  });

  test('re-recording a ref moves it to the front (dedup)', () {
    recordSpawnMru('alpha/a1', env: {}, tinaDir: tmp);
    recordSpawnMru('beta/b1', env: {}, tinaDir: tmp);
    recordSpawnMru('alpha/a1', env: {}, tinaDir: tmp);
    expect(loadSpawnMru(env: {}, tinaDir: tmp), ['alpha/a1', 'beta/b1']);
  });

  test('the stored list is capped', () {
    for (var i = 0; i < 30; i++) {
      recordSpawnMru('p/m$i', env: {}, tinaDir: tmp);
    }
    final mru = loadSpawnMru(env: {}, tinaDir: tmp);
    expect(mru.first, 'p/m29'); // most recent
    expect(mru.length, lessThanOrEqualTo(16));
  });

  test('a corrupt MRU file yields an empty list (no throw)', () {
    File(p.join(tmp.path, 'spawn_mru.json'))
        .writeAsStringSync('not json at all');
    expect(loadSpawnMru(env: {}, tinaDir: tmp), isEmpty);
  });
}
