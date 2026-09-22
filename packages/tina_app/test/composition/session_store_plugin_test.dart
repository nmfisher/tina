import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_environment.dart';
import '../helpers/fake_provider.dart';
import '../helpers/memory_session_store.dart';

ProviderRegistry _registry() => ProviderRegistry(env: const {})
  ..register(
    ProviderDescriptor(
      id: 'test',
      name: 'Test',
      authSources: const [],
      defaultBaseUrl: 'https://example.test',
      builder: (c) => FakeProvider.always(model: c.model),
    ),
  );

void main() {
  test(
      'buildAppComposition without a store override resolves the JSONL store '
      'from plugin scope (SP1)', () async {
    final comp = await buildAppComposition(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registry(),
      environment: FakeEnvironment(),
    );
    addTearDown(comp.dispose);

    // The store the app reads is the one bound under the service key —
    // same instance, not a second construction.
    expect(comp.store, isA<JsonlSessionStore>());
    expect(
      comp.pluginScope?.lookup(sessionStoreServiceKey),
      same(comp.store),
    );
  });

  test(
      'an injected store stays the composition store and bypasses the session '
      'plugin (tests keep their fakes)', () async {
    final store = MemorySessionStore();
    final comp = await buildAppComposition(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registry(),
      store: store,
      environment: FakeEnvironment(),
    );
    addTearDown(comp.dispose);

    expect(comp.store, same(store));
    // No jsonl binding: the plugin was not mounted.
    expect(
      comp.pluginScope?.lookup(sessionStoreServiceKey),
      isNull,
    );
  });

  test('composition dispose closes the plugin-owned store exactly once',
      () async {
    var closed = 0;
    final plugin = PluginDescriptor(
      id: 'test.counting-session-store',
      provides: [sessionStoreServiceKey],
      factory: FnPluginFactory((context) {
        final store = MemorySessionStore();
        context.own(() async {
          closed++;
        });
        return store;
      }),
    );
    final comp = await buildAppComposition(
      config: RuntimeConfig(provider: 'test', model: 'a'),
      registry: _registry(),
      plugins: [plugin],
    );
    // No store override, but an explicit plugin provides the key: the
    // composition must use IT (the extension seam is the alternative-backend
    // path), not the jsonl default.
    expect(comp.store, isA<MemorySessionStore>());
    expect(
      comp.pluginScope?.lookup(sessionStoreServiceKey),
      same(comp.store),
    );
    await comp.dispose();
    expect(closed, 1);
  });
}
