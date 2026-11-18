// Live check (L5): capture a search, resolve a differently-phrased
// query from the cache, show the freshness gate dropping a deleted
// path. Transcript for the ticket.
import 'dart:io';

import 'package:tina_memory/tina_memory.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('tina-cache-live-');
  final store = InMemoryMemoryStore();
  final cache = AnswerCache(persister: MemoryAnswerPersister(store));

  try {
    // The "repo": a few files a search would resolve to.
    File('${dir.path}/widget_builder.dart').writeAsStringSync('// widgets');
    File('${dir.path}/widget_test.dart').writeAsStringSync('// tests');

    print('== capture: "where does the app build its widgets"');
    final captured = cache.capture('where does the app build its widgets',
        ['${dir.path}/widget_builder.dart', '${dir.path}/widget_test.dart']);
    print('   terms=${captured!.terms} -> ${captured.paths.length} paths');
    print('   memory mirror: ${store.list().single.text}');

    print('== serve differently phrased: "app widgets builder location"');
    final served = cache.serve('app widgets builder location');
    print('   served=${served != null}');
    print('   alive paths=${served?.servedPaths}');
    print('   injection block:');
    print(cache.injectionBlock(served!));
    cache.accept(served);

    print('== freshness gate: delete one stored path');
    File('${dir.path}/widget_test.dart').deleteSync();
    final again = cache.serve('app widgets builder');
    print('   served=${again != null} paths=${again?.servedPaths} '
        '(deleted path dropped, not injected)');

    print('== full staleness: delete the other');
    File('${dir.path}/widget_builder.dart').deleteSync();
    final gone = cache.serve('app widgets builder');
    print('   served=${gone != null} (answer dropped, search proceeds)');

    print('== telemetry: ${cache.stats.toMap()}');
  } finally {
    store.close();
    dir.deleteSync(recursive: true);
  }
}
