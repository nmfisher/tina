import 'package:test/test.dart';
import 'package:tina_engine/src/runtime/plugin.dart';
import 'package:tina_engine/src/runtime/runtime.dart';

/// Marker object a fake plugin's factory returns for its service keys.
final class Instance {
  const Instance(this.pluginId);

  final String pluginId;

  @override
  String toString() => 'Instance($pluginId)';
}

/// Counts factory runs, to prove describe() never constructs a service.
final class Counter {
  int builds = 0;
}

PluginDescriptor _descriptor(
  String id, {
  Set<ServiceKey> requires = const <ServiceKey>{},
  List<ServiceKey> provides = const <ServiceKey>[],
  Counter? counter,
}) {
  return PluginDescriptor(
    id: id,
    requires: requires,
    provides: provides,
    factory: FnPluginFactory((context) {
      if (counter != null) counter.builds++;
      return Instance(id);
    }),
  );
}

void main() {
  test(
      'describe before activation reports pending and leaves the runtime '
      'untouched', () async {
    final runtime = PluginRuntime(name: 'r', plugins: [
      _descriptor('a'),
      _descriptor('b'),
    ]);

    final description = runtime.describe();
    expect(description.name, 'r');
    expect([for (final plugin in description.plugins) plugin.id], ['a', 'b']);
    expect(
      [for (final plugin in description.plugins) plugin.state],
      everyElement(PluginLifecycleState.pending),
    );
    expect(description.activationOrder, isEmpty);

    // The runtime itself was not mutated by describe().
    expect(runtime.stateOf('a'), PluginLifecycleState.pending);
    expect(runtime.stateOf('b'), PluginLifecycleState.pending);
    expect(runtime.activationOrder, isEmpty);

    // The described runtime still activates fine afterwards.
    await runtime.activate();
    expect(runtime.activationOrder, ['a', 'b']);
    await runtime.dispose();
  });

  test('describe never constructs a service', () async {
    final counter = Counter();
    final runtime = PluginRuntime(name: 'r', plugins: [
      _descriptor('counted', counter: counter),
    ]);

    final description = runtime.describe();
    expect(counter.builds, 0);
    expect(
      [for (final plugin in description.plugins) plugin.id],
      ['counted'],
    );

    await runtime.activate();
    expect(counter.builds, 1);
    await runtime.dispose();
  });

  test('dependsOn: a key with a single runtime provider yields the edge', () {
    final key = ServiceKey<String>('k');
    final runtime = PluginRuntime(name: 'r', plugins: [
      _descriptor('provider', provides: [key]),
      _descriptor('consumer', requires: {key}),
    ]);

    final description = runtime.describe();
    final consumer = description.plugins.firstWhere((p) => p.id == 'consumer');
    expect(consumer.requires, ['k']);
    expect(consumer.dependsOn, ['provider']);
    expect(
      description.plugins.firstWhere((p) => p.id == 'provider').dependsOn,
      isEmpty,
    );
    runtime.dispose();
  });

  test('dependsOn: a key provided only by the parent scope yields no edge',
      () async {
    final key = ServiceKey<String>('k');
    final parent = PluginRuntime(name: 'parent', plugins: [
      _descriptor('parent-provider', provides: [key]),
    ]);
    await parent.activate();

    final child = PluginRuntime(
      name: 'child',
      parent: parent.scope,
      plugins: [
        _descriptor('consumer', requires: {key}),
      ],
    );

    // Activation itself succeeds through the parent chain.
    await child.activate();

    final description = child.describe();
    expect(
      description.plugins.firstWhere((p) => p.id == 'consumer').dependsOn,
      isEmpty,
    );
    await child.dispose();
    await parent.dispose();
  });

  test('dependsOn: with several providers only the selected one gets the edge',
      () {
    final key = ServiceKey<String>('k');
    final runtime = PluginRuntime(name: 'r', plugins: [
      _descriptor('p1', provides: [key]),
      _descriptor('p2', provides: [key]),
      _descriptor('consumer', requires: {key}),
    ]);
    runtime.select('p2');

    final description = runtime.describe();
    final consumer = description.plugins.firstWhere((p) => p.id == 'consumer');
    expect(consumer.dependsOn, ['p2']);
    expect(
      description.plugins.firstWhere((p) => p.id == 'p1').dependsOn,
      isEmpty,
    );
    // p2 is the selected provider: it gets the consumer's edge, and nothing
    // links p1 to anyone.
    expect(
      description.plugins.firstWhere((p) => p.id == 'p2').dependsOn,
      isEmpty,
    );
    runtime.dispose();
  });

  test('dependsOn: several providers without a selection yield no edge', () {
    final key = ServiceKey<String>('k');
    final runtime = PluginRuntime(name: 'r', plugins: [
      _descriptor('p1', provides: [key]),
      _descriptor('p2', provides: [key]),
      _descriptor('consumer', requires: {key}),
    ]);

    final description = runtime.describe();
    expect(
      description.plugins.firstWhere((p) => p.id == 'consumer').dependsOn,
      isEmpty,
    );
    runtime.dispose();
  });

  test('toString renders the header and one plugin line per plugin', () {
    final key = ServiceKey<String>('k');
    final other = ServiceKey<int>('other');
    final runtime = PluginRuntime(name: 'r', plugins: [
      _descriptor('provider', provides: [key, other]),
      _descriptor('consumer', requires: {key}),
    ]);

    final text = runtime.describe().toString();
    expect(text, startsWith('runtime(r):'));
    expect(
      text,
      contains('plugin(id: consumer, state: pending, provides: [], '
          'requires: [k], dependsOn: [provider])'),
    );
    expect(
      text,
      contains('plugin(id: provider, state: pending, '
          'provides: [k, other], requires: [], dependsOn: [])'),
    );
    expect(text.split('\n'), hasLength(3));
    runtime.dispose();
  });

  test('describe after activation reports active and the activation order',
      () async {
    final key = ServiceKey<String>('k');
    final runtime = PluginRuntime(name: 'r', plugins: [
      _descriptor('z-provider', provides: [key]),
      _descriptor('a-consumer', requires: {key}),
    ]);
    await runtime.activate();

    final description = runtime.describe();
    // id-ascending even though activation followed declaration order.
    expect([for (final plugin in description.plugins) plugin.id],
        ['a-consumer', 'z-provider']);
    expect(
      [for (final plugin in description.plugins) plugin.state],
      everyElement(PluginLifecycleState.active),
    );
    expect(description.activationOrder, ['z-provider', 'a-consumer']);
    expect(description.activationOrder, runtime.activationOrder);
    await runtime.dispose();
  });
}
