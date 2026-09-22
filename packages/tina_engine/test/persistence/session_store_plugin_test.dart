import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tina_session_plugin_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('jsonlSessionStorePlugin', () {
    test('binds a JsonlSessionStore under the service key', () {
      final runtime = PluginRuntime(
        name: 'session-plugin-test',
        plugins: [jsonlSessionStorePlugin(root: tmp)],
      );
      addTearDown(runtime.dispose);
      runtime.activateSync();

      final store = runtime.scope.lookup(sessionStoreServiceKey);
      expect(store, isA<JsonlSessionStore>());
      expect((store as JsonlSessionStore).root.path, tmp.path);
    });

    test('scope teardown closes the store exactly once', () async {
      var closes = 0;
      final plugin = PluginDescriptor(
        id: 'test.counting-store',
        provides: [sessionStoreServiceKey],
        factory: FnPluginFactory((context) {
          final store = JsonlSessionStore(tmp);
          context.own(() async {
            closes++;
          });
          return store;
        }),
      );
      final runtime = PluginRuntime(
        name: 'session-plugin-count',
        plugins: [plugin],
      );
      runtime.activateSync();
      await runtime.dispose();
      expect(closes, 1);
    });

    test('two plugins providing the session store key fail at activation', () {
      final runtime = PluginRuntime(
        name: 'session-plugin-dup',
        plugins: [
          jsonlSessionStorePlugin(root: tmp),
          jsonlSessionStorePlugin(root: tmp),
        ],
      );
      expect(
        () => runtime.activateSync(),
        throwsA(isA<PluginCompositionError>()),
      );
    });

    test('default root matches the plugin default (no drift)', () {
      // The legacy constructor and the plugin must resolve the same
      // directory, or sessions would silently split across two roots.
      final legacy = JsonlSessionStore.defaultLocation();
      final runtime = PluginRuntime(
        name: 'session-plugin-default-root',
        plugins: [jsonlSessionStorePlugin()],
      );
      addTearDown(runtime.dispose);
      runtime.activateSync();
      final fromPlugin =
          runtime.scope.lookup(sessionStoreServiceKey) as JsonlSessionStore;
      expect(
        p.normalize(fromPlugin.root.path),
        p.normalize(legacy.root.path),
      );
    });
  });
}

