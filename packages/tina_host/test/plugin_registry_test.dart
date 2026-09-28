import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class NamedPlugin extends AgentPlugin {
  const NamedPlugin(this.id);
  @override
  final String id;
}

abstract interface class Service {
  String get value;
}

final class ServicePlugin extends AgentPlugin implements Service {
  ServicePlugin(this.id);
  @override
  final String id;
  @override
  String get value => 'injected';
}

const service = PluginCapability<Service>('acme/service');
const other = PluginCapability<AgentPlugin>('acme/other');

void main() {
  test(
      'dependency order and typed factory injection do not depend on selection order',
      () {
    final built = <String>[];
    final registry = PluginRegistry<void>();
    registry.registerDefinition(PluginDefinition.dependingOn<void, Service>(
        'acme/consumer',
        dependency: service, create: (_, dependency) {
      built.add(dependency.value);
      return const NamedPlugin('acme/consumer');
    }));
    registry.registerDefinition(PluginDefinition<void>('acme/provider', (_) {
      built.add('provider');
      return ServicePlugin('acme/provider');
    }, provides: [service]));
    expect(
        registry
            .build(['acme/consumer', 'acme/provider'], null).map((p) => p.id),
        ['acme/provider', 'acme/consumer']);
    expect(built, ['provider', 'injected']);
  });

  test(
      'missing, ambiguous and cyclic dependencies fail before creating resources',
      () {
    var builds = 0;
    final registry = PluginRegistry<void>();
    registry.registerDefinition(PluginDefinition.dependingOn<void, Service>(
        'acme/consumer',
        dependency: service,
        provides: [other], create: (_, dependency) {
      builds++;
      return const NamedPlugin('acme/consumer');
    }));
    for (final id in ['acme/first', 'acme/second']) {
      registry.registerDefinition(PluginDefinition<void>(id, (_) {
        builds++;
        return ServicePlugin(id);
      }, provides: [service]));
    }
    registry.registerDefinition(PluginDefinition.dependingOn<void, AgentPlugin>(
        'acme/cycle',
        dependency: other,
        provides: [service], create: (_, dependency) {
      builds++;
      return ServicePlugin('acme/cycle');
    }));
    for (final selection in [
      ['acme/consumer'],
      ['acme/consumer', 'acme/first', 'acme/second'],
      ['acme/consumer', 'acme/cycle'],
    ]) {
      expect(() => registry.build(selection, null), throwsArgumentError);
    }
    expect(builds, 0);
  });

  test('declared capabilities are checked against the actual implementation',
      () {
    final registry = PluginRegistry<void>();
    registry.registerDefinition(PluginDefinition<void>(
        'acme/liar', (_) => const NamedPlugin('acme/liar'),
        provides: [service]));
    expect(() => registry.build(['acme/liar'], null), throwsStateError);
  });

  test('tina is reserved; external publishers can share a local name', () {
    final registry = PluginRegistry<void>(firstParty: {
      'tina/plans': (_) => const NamedPlugin('tina/plans'),
    });
    registry.register('acme/plans', (_) => const NamedPlugin('acme/plans'));
    expect(registry.build(['tina/plans', 'acme/plans'], null).map((p) => p.id),
        ['tina/plans', 'acme/plans']);
    for (final id in ['tina/plans', 'tina/new-plugin']) {
      expect(() => registry.register(id, (_) => NamedPlugin(id)),
          throwsArgumentError);
    }
  });

  test('invalid, duplicate and unknown selections fail before factories run',
      () {
    var builds = 0;
    final registry = PluginRegistry<void>();
    registry.register('acme/review', (_) {
      builds++;
      return const NamedPlugin('acme/review');
    });
    for (final ids in [
      ['acme/review', 'unknown/plugin'],
      ['acme/review', 'acme/review'],
      ['review'],
      ['Tina/review'],
      ['acme/../review'],
    ]) {
      expect(() => registry.build(ids, null), throwsArgumentError);
    }
    expect(builds, 0);
    expect(
        () => registry.register(
            'acme/review', (_) => const NamedPlugin('acme/review')),
        throwsArgumentError);
  });

  test('a factory cannot claim another registered identity', () {
    final registry = PluginRegistry<void>();
    registry.register('acme/review', (_) => const NamedPlugin('tina/plans'));
    expect(() => registry.build(['acme/review'], null), throwsStateError);
  });

  test('the loop also rejects unqualified IDs outside the registry', () {
    expect(
        () => AgentLoop(
            provider: ScriptedProvider([]),
            plugins: [const NamedPlugin('plans')]),
        throwsArgumentError);
  });
}
