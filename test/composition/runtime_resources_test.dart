import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_provider.dart';
import '../helpers/memory_session_store.dart';

class _Store extends MemorySessionStore {
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
  }
}

class _Provider extends FakeProvider {
  int closes = 0;
  _Provider() : super(const []);
  @override
  void close() {
    closes++;
  }
}

void main() {
  test(
    'cleanup is reversed, exhaustive and shared by concurrent callers',
    () async {
      final order = <int>[];
      final gate = Completer<void>();
      final resources = RuntimeResources()
        ..own(() {
          order.add(1);
        })
        ..own(() {
          order.add(2);
          throw StateError('cleanup');
        })
        ..own(() async {
          await gate.future;
          order.add(3);
        });
      final first = resources.dispose();
      expect(resources.dispose(), same(first));
      expect(() => resources.own(() {}), throwsStateError);
      gate.complete();
      await expectLater(first, throwsStateError);
      expect(order, [3, 2, 1]);
      await expectLater(resources.dispose(), throwsStateError);
      expect(order, [3, 2, 1]);
    },
  );

  test('work failure survives cleanup failure', () async {
    final resources = RuntimeResources()
      ..own(() => throw StateError('cleanup'));
    final failure = ArgumentError('work');
    await expectLater(
      resources.run(() async => throw failure),
      throwsA(same(failure)),
    );
  });

  for (final owned in [false, true]) {
    for (final fail in [false, true]) {
      test(
        'composition ownership: owned store=$owned, failure=$fail',
        () async {
          final root = Directory.systemTemp.createTempSync('runtime-disposal-');
          addTearDown(() => root.deleteSync(recursive: true));
          final providers = <_Provider>[];
          final registry = ProviderRegistry(env: const {})
            ..register(
              ProviderDescriptor(
                id: 'test',
                name: 'Test',
                authSources: const [],
                defaultBaseUrl: 'https://example.test',
                builder: (_) {
                  final p = _Provider();
                  providers.add(p);
                  return p;
                },
              ),
            );
          final config = Config.parse(
            [
              '--model',
              'test/model',
              '--no-sandbox',
              if (fail) ...['--resume', 'missing-session'],
            ],
            env: const {},
            registry: registry,
          );
          final store = _Store();
          final build = buildAppComposition(
            config: config.runtime,
            resumeRequest: config.resumeRequest,
            registry: registry,
            projectRoot: root.path,
            store: store,
            ownsStore: owned,
          );
          if (fail) {
            await expectLater(build, throwsA(anything));
          } else {
            final app = await build;
            final conversation = app.buildStartupProvider();
            await Future.wait([app.dispose(), app.dispose()]);
            expect(providers.last.closes, 0); // conversation owns this provider
            conversation.close();
            expect(providers.last.closes, 1);
            expect(app.buildStartupProvider, throwsStateError);
            expect(() => app.providers.build('test/model'), throwsStateError);
          }
          expect(
            providers.first.closes,
            1,
          ); // classifier is always runtime-owned
          expect(store.closes, owned ? 1 : 0);
          if (!owned) {
            await store.createSession(providerId: 'still-usable');
            await store.close();
          }
        },
      );
    }
  }
}
