import 'package:test/test.dart';
import 'package:tina_engine/src/runtime/plugin.dart';
import 'package:tina_engine/src/runtime/runtime.dart';

/// Marker object a fake plugin's factory returns for its service key.
final class Instance {
  const Instance(this.pluginId);

  final String pluginId;

  @override
  String toString() => 'Instance($pluginId)';
}

/// Makes fake [PluginDescriptor]s whose factories record activation calls,
/// register owned resources with the scope, and can throw.
///
/// When [build] is given it replaces the default behavior entirely: it owns
/// registering cleanups and throwing.
final class Recorder {
  /// Plugin ids in the order their factories ran.
  final List<String> activations = <String>[];

  /// Cleanup labels in the order cleanups ran.
  final List<String> cleanups = <String>[];

  PluginDescriptor plugin(
    String id, {
    Set<ServiceKey> requires = const <ServiceKey>{},
    List<ServiceKey> provides = const <ServiceKey>[],
    bool fails = false,
    bool ownsCleanup = false,
    String? cleanupLabel,
    Object Function(PluginContext context)? build,
  }) {
    return PluginDescriptor(
      id: id,
      requires: requires,
      provides: provides,
      factory: FnPluginFactory((context) {
        activations.add(id);
        if (build != null) return build(context);
        if (ownsCleanup) {
          context.own(() => cleanups.add(cleanupLabel ?? id));
        }
        if (fails) throw StateError('plugin "$id" exploded while building');
        return Instance(id);
      }),
    );
  }
}

/// Matches a message that names every string in [parts].
Matcher messageNaming(Iterable<String> parts) => predicate<String>(
      (message) => parts.every(message.contains),
      'a message naming ${parts.join(', ')}',
    );

/// Matches a future that fails with a [PluginCompositionError] whose message
/// names every string in [parts].
Matcher throwsCompositionError(Iterable<String> parts) => throwsA(
      isA<PluginCompositionError>().having(
        (error) => error.toString(),
        'message',
        messageNaming(parts),
      ),
    );

void main() {
  group('validation', () {
    test('rejects a duplicate plugin id', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('twin'),
        rec.plugin('twin'),
      ]);

      await expectLater(
        rt.activate(),
        throwsCompositionError(['duplicate', 'twin']),
      );
      expect(rec.activations, isEmpty);
    });

    test('rejects a missing dependency', () async {
      final rec = Recorder();
      final db = ServiceKey<Object>('db');
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('consumer', requires: {db}),
      ]);

      await expectLater(
        rt.activate(),
        throwsCompositionError(['consumer', 'db']),
      );
      expect(rec.activations, isEmpty);
    });

    test('rejects a dependency cycle', () async {
      final rec = Recorder();
      final svcA = ServiceKey<Object>('svc-a');
      final svcB = ServiceKey<Object>('svc-b');
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('p1', requires: {svcB}, provides: [svcA]),
        rec.plugin('p2', requires: {svcA}, provides: [svcB]),
      ]);

      await expectLater(
        rt.activate(),
        throwsCompositionError(['cycle', 'p1', 'p2']),
      );
      expect(rec.activations, isEmpty);
    });

    test('rejects two providers of one key with no selection', () async {
      final rec = Recorder();
      final shared = ServiceKey<Object>('shared');
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('pa', provides: [shared]),
        rec.plugin('pb', provides: [shared]),
      ]);

      await expectLater(
        rt.activate(),
        throwsCompositionError(['shared', 'pa', 'pb', 'select()']),
      );
      expect(rec.activations, isEmpty);
    });

    test('select() refuses a second selection of the same key', () {
      final rec = Recorder();
      final shared = ServiceKey<Object>('shared');
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('pa', provides: [shared]),
        rec.plugin('pb', provides: [shared]),
      ]);
      rt.select('pa');

      expect(
        () => rt.select('pb'),
        throwsCompositionError(['shared', 'pa', 'pb']),
      );
    });

    test('rejects a config block its decoder cannot decode', () async {
      final rec = Recorder();
      final rt = PluginRuntime(
        name: 'rt',
        config: const {
          'cfgd': {'port': 'nope'},
        },
        plugins: [
          PluginDescriptor(
            id: 'cfgd',
            decodeConfig: (raw) => throw const PluginConfigException(
              'cfgd',
              'port must be an int',
            ),
            factory: FnPluginFactory((_) => Instance('cfgd')),
          ),
        ],
      );

      await expectLater(
        rt.activate(),
        throwsCompositionError(['cfgd', 'port must be an int']),
      );
      expect(rec.activations, isEmpty);
    });

    test('a decoder receives only its own config block', () async {
      final seen = <Object?>[];
      final rt = PluginRuntime(
        name: 'rt',
        config: const {
          'cfgd': {'port': 8080},
          'other': {'port': 'not-for-cfgd'},
        },
        plugins: [
          PluginDescriptor(
            id: 'cfgd',
            decodeConfig: (raw) {
              seen.add(raw);
              return raw;
            },
            factory: FnPluginFactory((_) => Instance('cfgd')),
          ),
        ],
      );

      await rt.activate();

      expect(seen, [
        {
          'port': 8080,
        },
      ]);
      expect(rt.decodedConfigs['cfgd'], {'port': 8080});
    });

    test('a missing config block decodes to an empty map', () async {
      final seen = <Object?>[];
      final rt = PluginRuntime(
        name: 'rt',
        config: const {
          'other': {'ignored'}
        },
        plugins: [
          PluginDescriptor(
            id: 'cfgd',
            decodeConfig: (raw) {
              seen.add(raw);
              return raw;
            },
            factory: FnPluginFactory((_) => Instance('cfgd')),
          ),
        ],
      );

      await rt.activate();

      expect(seen, [const <String, Object?>{}]);
      expect(rt.decodedConfigs['cfgd'], isEmpty);
    });

    test('a failed validation runs no factory and leaves no state', () async {
      final rec = Recorder();
      final shared = ServiceKey<Object>('shared');
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('pa', provides: [shared]),
        rec.plugin('pb', provides: [shared]),
      ]);

      await expectLater(rt.activate(), throwsCompositionError(['shared']));

      expect(rec.activations, isEmpty);
      expect(rec.cleanups, isEmpty);
      expect(rt.scope.lookup(shared), isNull);
      expect(rt.stateOf('pa'), PluginLifecycleState.pending);
      expect(rt.stateOf('pb'), PluginLifecycleState.pending);
    });
  });

  group('ordering', () {
    test('activates a dependency before its dependent', () async {
      final rec = Recorder();
      final db = ServiceKey<Object>('db');
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('app', requires: {db}),
        rec.plugin('db-provider', provides: [db]),
      ]);

      await rt.activate();

      expect(rec.activations, ['db-provider', 'app']);
      expect(rt.activationOrder, ['db-provider', 'app']);
    });

    test('breaks ordering ties by plugin id ascending', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('zeta'),
        rec.plugin('mid'),
        rec.plugin('alpha'),
      ]);

      await rt.activate();

      expect(rec.activations, ['alpha', 'mid', 'zeta']);
    });

    test('activationOrder is frozen', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('b'),
        rec.plugin('a'),
      ]);
      await rt.activate();

      final order = rt.activationOrder;
      expect(() => order.add('intruder'), throwsA(isA<UnsupportedError>()));
      expect(rt.activationOrder, ['a', 'b']);
    });
  });

  group('failed activation rollback', () {
    test('rolls back plugins that already activated', () async {
      final rec = Recorder();
      final db = ServiceKey<Object>('db');
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('db-provider', provides: [db], ownsCleanup: true),
        rec.plugin('broken', requires: {db}, fails: true),
      ]);

      await expectLater(
        rt.activate(),
        throwsA(
          isA<PluginCompositionError>()
              .having((error) => error.pluginId, 'pluginId', 'broken')
              .having(
                (error) => error.chain,
                'chain',
                contains('db-provider'),
              )
              .having(
                (error) => error.toString(),
                'message',
                messageNaming(['broken', 'db-provider']),
              ),
        ),
      );

      expect(rec.activations, ['db-provider', 'broken']);
      expect(rec.cleanups, ['db-provider']);
    });

    test('parent-runtime resources survive a child runtime failure', () async {
      final rec = Recorder();
      final config = ServiceKey<Object>('config');
      final parent = PluginRuntime(name: 'parent', plugins: [
        rec.plugin('host', provides: [config], ownsCleanup: true),
      ]);
      await parent.activate();

      final child = PluginRuntime(
        name: 'child',
        parent: parent.scope,
        plugins: [
          rec.plugin('borrower', requires: {config}),
          rec.plugin('broken', fails: true),
        ],
      );

      await expectLater(child.activate(), throwsCompositionError(['broken']));

      expect(rec.cleanups, isEmpty);
      expect(parent.stateOf('host'), PluginLifecycleState.active);
      expect(parent.scope.lookup(config), isA<Instance>());
    });
  });

  group('teardown', () {
    test('releases cleanups in reverse acquisition order', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('p1', ownsCleanup: true),
        rec.plugin('p2', ownsCleanup: true),
        rec.plugin('p3', ownsCleanup: true),
      ]);

      await rt.activate();
      await rt.dispose();

      expect(rec.cleanups, ['p3', 'p2', 'p1']);
    });

    test('a cleanup error does not stop later cleanups; the first wins',
        () async {
      final rec = Recorder();
      final ran = <String>[];
      final err = Exception('cleanup boom');
      StackTrace? cleanupStack;
      final rt = PluginRuntime(name: 'rt', plugins: [rec.plugin('p')]);
      await rt.activate();

      rt.scope.resources.own(() => ran.add('first-acquired'));
      rt.scope.resources.own(() {
        try {
          throw err;
        } catch (error, stackTrace) {
          cleanupStack = stackTrace;
          rethrow;
        }
      });
      rt.scope.resources.own(() => ran.add('last-acquired'));

      await expectLater(rt.dispose(), throwsA(same(err)));
      expect(ran, ['last-acquired', 'first-acquired']);
      expect(rt.stateOf('p'), PluginLifecycleState.disposed);

      // dispose() is memoized: the second call rethrows the same error with
      // the original stack trace.
      StackTrace? rethrownStack;
      try {
        await rt.dispose();
      } catch (error, stackTrace) {
        expect(error, same(err));
        rethrownStack = stackTrace;
      }
      expect(rethrownStack, isNotNull);
      expect(rethrownStack, same(cleanupStack));
    });

    test('dispose is idempotent: same future, cleanups run once', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('p', ownsCleanup: true),
      ]);
      await rt.activate();

      final first = rt.dispose();
      await first;
      expect(rec.cleanups, ['p']);

      final second = rt.dispose();
      expect(second, same(first));
      await second;
      expect(rec.cleanups, ['p']);
    });

    test('child scopes are disposed before the root scope', () async {
      final order = <String>[];
      final rt = PluginRuntime(name: 'rt', plugins: const []);
      rt.scope.resources.own(() => order.add('root'));
      final child = rt.childScope('child');
      child.resources.own(() => order.add('child'));
      final grandchild = child.child('grandchild');
      grandchild.resources.own(() => order.add('grandchild'));

      await rt.dispose();

      expect(order, ['grandchild', 'child', 'root']);
    });

    test('run keeps the work failure when a cleanup also fails', () async {
      final workError = Exception('work boom');
      final cleanupError = Exception('cleanup boom');
      final resources = ScopeResources();
      resources.own(() => throw cleanupError);

      await expectLater(
        resources.run(() async => throw workError),
        throwsA(same(workError)),
      );
      expect(resources.isClosing, isTrue);
    });
  });

  group('contributions and services', () {
    test('rejects a duplicate contribution id in one scope', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('p1', build: (context) {
          context.register('from-p1', id: 'tool');
          return Instance('p1');
        }),
        rec.plugin('p2', build: (context) {
          context.register('from-p2', id: 'tool');
          return Instance('p2');
        }),
      ]);

      await expectLater(
        rt.activate(),
        throwsCompositionError(['tool', 'p2']),
      );

      expect(rt.scope.contributions.single.pluginId, 'p1');
    });

    test('addContribution rejects a duplicate id naming both plugins', () {
      final scope = PluginScope('solo');
      scope.addContribution(
        const Contribution(id: 'cmd', pluginId: 'a', contribution: 'A'),
        Registration.create('cmd', null),
      );

      expect(
        () => scope.addContribution(
          const Contribution(id: 'cmd', pluginId: 'b', contribution: 'B'),
          Registration.create('cmd-b', null),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            messageNaming(['cmd', 'a', 'b']),
          ),
        ),
      );
    });

    test('register returns a handle that releases early and stays idempotent',
        () async {
      final released = <String>[];
      Registration? handle;
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('host', build: (context) {
          handle = context.register(
            'host-tool',
            id: 'tool',
            dispose: () => released.add('tool'),
          );
          return Instance('host');
        }),
      ]);
      await rt.activate();

      // Releasing through the handle is immediate and idempotent: a second
      // call is a no-op, so `tool` is recorded once.
      await handle!.dispose();
      await handle!.dispose();
      expect(released, ['tool']);

      // Scope teardown is the backstop but does not run the dispose again.
      await rt.dispose();
      expect(released, ['tool']);
    });

    test('the same contribution id is fine across parent and child scopes',
        () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'parent', plugins: [
        rec.plugin('host', build: (context) {
          context.register('host-tool', id: 'tool');
          return Instance('host');
        }),
      ]);
      await rt.activate();

      final child = rt.childScope('child');
      child.addContribution(
        const Contribution(id: 'tool', pluginId: 'guest', contribution: 'x'),
        Registration.create('tool', null),
      );

      expect(rt.scope.contributions.single.id, 'tool');
      expect(rt.scope.contributions.single.pluginId, 'host');
      expect(child.contributions.single.id, 'tool');
      expect(child.contributions.single.pluginId, 'guest');
    });

    test('provide() without replace refuses to overwrite a bound key', () {
      final key = ServiceKey<String>('svc');
      final scope = PluginScope('solo');
      scope.provide(key, 'first');

      expect(
        () => scope.provide(key, 'second'),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            messageNaming(['svc', 'solo', 'replace']),
          ),
        ),
      );
      expect(scope.lookup(key), 'first');
    });

    test('provide() with replace: true installs the new instance', () {
      final key = ServiceKey<String>('svc');
      final scope = PluginScope('solo');
      scope.provide(key, 'first');

      scope.provide(key, 'second', replace: true);

      expect(scope.lookup(key), 'second');
    });

    test('a child scope may shadow a parent key', () {
      final key = ServiceKey<String>('svc');
      final parent = PluginScope('parent');
      parent.provide(key, 'parent-value');

      final child = parent.child('child');
      child.provide(key, 'child-value');

      expect(child.lookup(key), 'child-value');
      expect(parent.lookup(key), 'parent-value');
    });

    test('context.require names the plugin and the missing key', () {
      final ghost = ServiceKey<Object>('ghost');
      final context = PluginContext(
        plugin: PluginDescriptor(
          id: 'needy',
          factory: FnPluginFactory((_) => Instance('needy')),
        ),
        scope: PluginScope('solo'),
      );

      expect(
        () => context.require(ghost),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            messageNaming(['needy', 'ghost']),
          ),
        ),
      );
    });
  });

  group('states', () {
    test('stateOf moves from pending to active after activate', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('a'),
        rec.plugin('b'),
      ]);

      expect(rt.stateOf('a'), PluginLifecycleState.pending);
      expect(rt.stateOf('b'), PluginLifecycleState.pending);

      await rt.activate();

      expect(rt.stateOf('a'), PluginLifecycleState.active);
      expect(rt.stateOf('b'), PluginLifecycleState.active);
    });

    test('every plugin reports disposed after dispose', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('a'),
        rec.plugin('b'),
      ]);
      await rt.activate();
      await rt.dispose();

      expect(rt.stateOf('a'), PluginLifecycleState.disposed);
      expect(rt.stateOf('b'), PluginLifecycleState.disposed);
    });

    test('stateOf throws ArgumentError for an unknown id', () {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [rec.plugin('a')]);

      expect(() => rt.stateOf('nope'), throwsArgumentError);
    });
  });
}
