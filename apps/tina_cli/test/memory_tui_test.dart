// /memory end to end through the real assembly: the native catalog
// wires the command with the CLI's store-opening path, so the
// keyboard mutators write the real rolling-memory databases for the
// workspace (origin-less temp dirs get the per-workspace sandbox
// keying — never shared). Behavioral assertions only; rendering is
// covered by the session-controls command tests.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_memory/tina_memory_sqlite.dart';
import 'package:tina/tui.dart';

class _Echo extends LlmProvider {
  _Echo(super.model);
  @override
  Stream<StreamEvent> send(
          {required String system,
          required List<Message> messages,
          required List<ToolSchema> tools}) =>
      Stream.fromIterable(scriptedReply('hello'));
}

void main() {
  late Directory root;
  late File config;

  SessionAssembly open() => SessionAssembly.start(
        providerFactory: (model) => _Echo(model),
        options: AssemblyOptions(
          configPath: config.path,
          workingDirectory: root.path,
        ),
      );

  setUp(() {
    root = Directory(Directory.systemTemp.createTempSync('tina-memory-tui-')
        .resolveSymbolicLinksSync());
    addTearDown(() => root.deleteSync(recursive: true));
    config = File('${root.path}/config')
      ..writeAsStringSync('version = 1\n'
          '[default]\nprovider = "local"\nmodel = "m"\n'
          '[providers.local]\nbase_url = "http://localhost:1234/v1"\n'
          'models = ["m"]\n');
  });

  test('remember, list-free reads and forget go through the real store',
      () async {
    final app = open();
    addTearDown(app.close);

    // The command is registered by the catalog and the mutators write
    // the workspace's actual databases (the same pair the CLI opens).
    expect(await app.handleCommand('/memory'), isTrue);
    expect(
        await app.handleCommand(
            '/memory remember the config lives at ./config --category paths'),
        isTrue);
    expect(await app.handleCommand('/memory stats'), isTrue);

    final stores = openDefaultMemoryStores(root.path);
    addTearDown(stores.close);
    final stored = stores.project.list();
    expect(stored.single.text, 'the config lives at ./config');
    expect(stored.single.updatedBy, 'human');
    expect(stored.single.category, MemoryCategory.paths);

    // Search finds it — through the pair the CLI would open.
    expect(stores.recall('./config').map((e) => e.id),
        contains(stored.single.id));

    expect(
        await app.handleCommand('/memory forget ${stored.single.id}'), isTrue);
    expect(stores.project.list(), isEmpty);
  });
}
