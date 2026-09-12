import 'dart:async';

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

    test('a child created during another child\'s async cleanup is rejected',
        () async {
      final gate = Completer<void>();
      final firstCleanupStarted = Completer<void>();
      final order = <String>[];
      final rt = PluginRuntime(name: 'rt', plugins: const []);
      final first = rt.childScope('first');
      first.resources.own(() async {
        firstCleanupStarted.complete();
        await gate.future;
        order.add('first-cleanup');
      });

      final disposal = rt.dispose();
      // Park INSIDE the drain: first's async cleanup is running, so the
      // runtime is mid-teardown. A child created here used to slip past the
      // pre-drain descendant snapshot (and past the override's missing
      // admission check) and was never disposed.
      await firstCleanupStarted.future;

      Object? rejection;
      try {
        rt.childScope('late');
      } catch (error) {
        rejection = error;
      }
      expect(rejection, isA<StateError>(),
          reason: 'admission closes across the scope tree before the drain, '
              'so a child created mid-teardown is rejected, not silently '
              'admitted and leaked');

      gate.complete();
      await disposal;

      expect(order, ['first-cleanup'],
          reason: 'the child that existed before the close is disposed');
      expect(rt.scope.isAdmitting, isFalse,
          reason: 'no resource is left undisposed: the whole tree is closed');
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
      Contribution? seenBeforeRollback;
      Object? duplicateError;
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('p1', build: (context) {
          context.register('from-p1', id: 'tool');
          return Instance('p1');
        }),
        rec.plugin('p2', build: (context) {
          // The duplicate id rejects INSIDE p2's factory. Snapshot the scope
          // membership at the moment of the failure — after the awaited
          // rollback the scope is fully drained, which is the post-Fix 6
          // contract (activation rejects only after teardown completed).
          try {
            context.register('from-p2', id: 'tool');
          } catch (e) {
            duplicateError = e;
            seenBeforeRollback = context.scope.contributions.single;
            rethrow; // the factory must still fail so activation rejects
          }
          return Instance('p2');
        }),
      ]);

      await expectLater(
        rt.activate(),
        throwsCompositionError(['tool', 'p2']),
      );

      expect(duplicateError, isA<StateError>());
      expect(seenBeforeRollback, isNotNull,
          reason: 'at the moment of rejection, p1\'s contribution was still '
              'live in the scope');
      expect(seenBeforeRollback!.pluginId, 'p1');
      expect(rt.isFailed, isTrue,
          reason: 'the runtime reached the terminal failed state');
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

  group('runtime disposal goes through the scope', () {
    test('dispose removes owned services and closes admission', () async {
      final ledger = ServiceKey<Object>('ledger');
      final rt = PluginRuntime(name: 'rt', plugins: [
        Recorder().plugin('ledger', provides: [ledger]),
      ]);
      await rt.activate();
      expect(rt.scope.lookup(ledger), isNotNull);

      await rt.dispose();

      expect(
        () => rt.scope.lookup(ledger),
        throwsStateError,
        reason: 'the released service must not stay discoverable after '
            'runtime disposal (bare resources.dispose() left it bound)',
      );
      expect(rt.scope.isAdmitting, isFalse,
          reason: 'admission must close with the scope, not stay open');
    });
  });

  group('activation lifecycle', () {
    test('a second activate() rejects and re-runs no factory', () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        // A contribution-only factory: if activation ran twice, the second
        // pass would trip the duplicate contribution id 'tool' instead of
        // silently building the plugin set again.
        rec.plugin('host', build: (context) {
          context.register('host-tool', id: 'tool');
          return Instance('host');
        }),
        rec.plugin('plain'),
      ]);

      await rt.activate();
      expect(rec.activations, ['host', 'plain']);

      await expectLater(
        rt.activate(),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            messageNaming(['rt', 'activate', 'once']),
          ),
        ),
      );

      // Each factory ran exactly once; the live scope is untouched.
      expect(rec.activations, ['host', 'plain']);
      expect(rt.scope.contributions.single.id, 'tool');

      // The sync twin shares the same one-shot gate.
      expect(
        () => rt.activateSync(),
        throwsA(isA<StateError>()),
      );
      expect(rec.activations, ['host', 'plain']);
    });
  });

  group('failed activation awaits rollback', () {
    test('activate() rejects only after rollback drained the scope',
        () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('db', provides: [ServiceKey<Object>('db')],
            ownsCleanup: true),
        rec.plugin('broken', requires: {ServiceKey<Object>('db')},
            fails: true),
      ]);

      await expectLater(rt.activate(), throwsA(isA<PluginCompositionError>()));

      // Post-contract: activation rejects AFTER teardown. The cleanup list
      // is already drained by the time the caller sees the error, and the
      // runtime is terminally failed.
      expect(rec.cleanups, ['db'],
          reason: 'rollback completed BEFORE activate() rejected — a '
              'replacement startup cannot overlap teardown');
      expect(rt.isFailed, isTrue);
      expect(rt.scope.isAdmitting, isFalse);
    });

    test('dispose() after a failed activation shares the rollback completion',
        () async {
      final rec = Recorder();
      final rt = PluginRuntime(name: 'rt', plugins: [
        rec.plugin('db', provides: [ServiceKey<Object>('db')],
            ownsCleanup: true),
        rec.plugin('broken', requires: {ServiceKey<Object>('db')},
            fails: true),
      ]);
      await expectLater(rt.activate(), throwsA(anything));
      final rollbackCleanups = List<String>.from(rec.cleanups);

      // dispose() must not run cleanups twice: it shares the rollback.
      await rt.dispose();
      expect(rec.cleanups, rollbackCleanups,
          reason: 'rollback cleanups ran exactly once');
    });
  });

  group('registration id reuse during disposal', () {
    for (final asyncFailure in [false, true]) {
      test('cleanup failure releases the id (async: $asyncFailure)', () async {
        final scope = PluginScope('failed-cleanup');
        final failure = StateError('cleanup failed');
        var cleanupCalls = 0;
        final old = scope.registerContribution(
          pluginId: 'old', contribution: 'old', id: 'tool',
          dispose: () {
            cleanupCalls++;
            if (asyncFailure) return Future<void>.error(failure);
            throw failure;
          },
        );
        final closing = old.dispose();
        expect(old.dispose(), same(closing));
        await expectLater(closing, throwsA(same(failure)));
        expect(old.isDisposalComplete, isTrue);
        expect(scope.contributions, isEmpty);

        var replacementCleaned = false;
        final fresh = scope.registerContribution(
          pluginId: 'new', contribution: 'new', id: 'tool',
          dispose: () { replacementCleaned = true; },
        );
        await expectLater(old.dispose(), throwsA(same(failure)));
        expect(scope.contributions.single.contribution, 'new');
        expect(cleanupCalls, 1);
        // Scope teardown still reports the original cleanup error and also
        // releases the replacement. The failed callback is never rerun.
        await expectLater(scope.dispose(), throwsA(same(failure)));
        expect(fresh.isDisposalComplete, isTrue);
        expect(replacementCleaned, isTrue);
        expect(cleanupCalls, 1);
      });
    }

    test('reusing an id while the old registration is mid-disposal rejects',
        () async {
      final scope = PluginScope('reuse');
      final gate = Completer<void>();
      var cleanupStarted = false;
      var cleanupRan = false;
      final old = scope.registerContribution(
        pluginId: 'old-plugin',
        contribution: 'old',
        id: 'tool',
        dispose: () async {
          cleanupStarted = true;
          await gate.future;
          cleanupRan = true;
        },
      );
      old.dispose();
      // Wait until the disposal has actually STARTED (the cleanup is parked
      // on the gate). The earlier version of this test asserted before the
      // dispose microtask ran, so it passed even while the id reservation
      // was already dropped at dispose-start.
      while (!cleanupStarted) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(cleanupRan, isFalse,
          reason: 'the cleanup must still be running for this to be the '
              'mid-disposal gap');
      expect(scope.contributions, isEmpty,
          reason: 'membership is revoked the moment disposal begins');

      expect(
        () => scope.registerContribution(
          pluginId: 'new-plugin',
          contribution: 'new',
          id: 'tool',
        ),
        throwsA(isA<StateError>().having((e) => e.toString(), 'message',
            predicate((String m) => m.contains('still disposing')))),
        reason: 'id reuse must wait for the old disposal to finish',
      );

      gate.complete();
      await old.dispose(); // drain
      expect(cleanupRan, isTrue);
      expect(scope.contributions, isEmpty,
          reason: 'the old cleanup revokes only its own membership — the '
              'id is now free, nothing else was touched');

      // After completion the id is reusable.
      final fresh = scope.registerContribution(
        pluginId: 'new-plugin',
        contribution: 'new',
        id: 'tool',
      );
      expect(fresh.isDisposed, isFalse);
      expect(scope.contributions.single.contribution, 'new');
    });

    test('the old cleanup revokes by identity: a completed-disposal reuse '
        'keeps the new registration live', () async {
      final scope = PluginScope('identity');
      final old = scope.registerContribution(
        pluginId: 'old-plugin',
        contribution: 'old',
        id: 'tool',
        dispose: () {},
      );
      await old.dispose(); // completes fully

      final fresh = scope.registerContribution(
        pluginId: 'new-plugin',
        contribution: 'new',
        id: 'tool',
      );
      expect(scope.contributions.single.contribution, 'new');
      final newMembership = scope.contributions.single;

      // Old-cleanup path: even if the old handle is disposed again, its
      // revoke matches by IDENTITY — the surviving membership is the very
      // instance the new registration installed, never a by-id deletion.
      await old.dispose();
      expect(scope.contributions.single, same(newMembership),
          reason: 'the old cleanup must not touch the new registration '
              'under the same id');
      expect(fresh.isDisposed, isFalse);
    });
  });
}
