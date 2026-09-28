import 'package:tina_engine_2/tina_engine_2.dart';
import 'plugin_definition.dart';

typedef PluginFactory<C> = AgentPlugin Function(C context);

/// Application catalog. Only its constructor may register first-party names.
/// Dependency graphs are validated before any factory is called.
final class PluginRegistry<C> {
  PluginRegistry(
      {Map<String, PluginFactory<C>> firstParty = const {},
      List<PluginDefinition<C>> definitions = const [],
      Set<String> liveFirstParty = const {}}) {
    for (final definition in [
      for (final entry in firstParty.entries)
        PluginDefinition<C>(entry.key, entry.value,
            live: liveFirstParty.contains(entry.key)),
      ...definitions,
    ]) {
      if (!definition.id.startsWith('tina/')) {
        throw ArgumentError(
            'first-party plugin must use tina/: ${definition.id}');
      }
      _add(definition);
    }
  }

  final _definitions = <String, PluginDefinition<C>>{};

  void _add(PluginDefinition<C> definition) {
    validatePluginId(definition.id);
    if (_definitions.containsKey(definition.id)) {
      throw ArgumentError('duplicate plugin id: ${definition.id}');
    }
    _definitions[definition.id] = definition;
  }

  Iterable<String> get ids => _definitions.keys;
  PluginDefinition<C> definition(String id) =>
      _definitions[id] ?? (throw ArgumentError('unknown plugin: $id'));
  List<String> orderedIds(Iterable<String> ids) =>
      _ordered(ids).map((d) => d.id).toList();

  void register(String id, PluginFactory<C> factory, {bool live = false}) =>
      registerDefinition(PluginDefinition(id, factory, live: live));

  void registerDefinition(PluginDefinition<C> definition) {
    if (definition.id.startsWith('tina/')) {
      throw ArgumentError(
          'the tina namespace is reserved for first-party plugins');
    }
    _add(definition);
  }

  void validate(Iterable<String> ids) {
    _ordered(ids);
  }

  List<PluginDefinition<C>> _ordered(Iterable<String> ids) {
    final selected = <String, PluginDefinition<C>>{};
    final providers = <String, PluginDefinition<C>>{};
    for (final id in ids) {
      validatePluginId(id);
      if (selected.containsKey(id))
        throw ArgumentError('duplicate plugin id: $id');
      final definition = _definitions[id];
      if (definition == null) throw ArgumentError('unknown plugin: $id');
      selected[id] = definition;
      for (final capability in definition.provides) {
        if (providers.containsKey(capability.name)) {
          throw ArgumentError('multiple providers for ${capability.name}: '
              '${providers[capability.name]!.id}, $id');
        }
        providers[capability.name] = definition;
      }
    }
    final visiting = <String>{};
    final visited = <String>{};
    final ordered = <PluginDefinition<C>>[];
    void visit(PluginDefinition<C> definition) {
      if (visited.contains(definition.id)) return;
      if (!visiting.add(definition.id)) {
        throw ArgumentError('plugin dependency cycle at ${definition.id}');
      }
      for (final dependency in definition.requires) {
        final provider = providers[dependency.name];
        if (provider == null) {
          throw ArgumentError(
              '${definition.id} requires ${dependency.name}; no provider selected');
        }
        visit(provider);
      }
      visiting.remove(definition.id);
      visited.add(definition.id);
      ordered.add(definition);
    }

    for (final definition in selected.values) {
      visit(definition);
    }
    return ordered;
  }

  List<AgentPlugin> build(List<String> ids, C context,
      {Iterable<AgentPlugin> existing = const []}) {
    final ordered = _ordered(ids);
    final capabilities = <String, Object>{};
    final built = <AgentPlugin>[];
    final retained = {for (final plugin in existing) plugin.id: plugin};
    try {
      for (final definition in ordered) {
        final dependencies = <Object>[];
        for (final dependency in definition.requires) {
          final value = capabilities[dependency.name]!;
          if (!dependency.accepts(value)) {
            throw StateError('invalid provider for ${dependency.name}');
          }
          dependencies.add(value);
        }
        final plugin =
            retained[definition.id] ?? definition.build(context, dependencies);
        if (!retained.containsKey(definition.id)) built.add(plugin);
        if (plugin.id != definition.id) {
          throw StateError(
              'factory for ${definition.id} returned plugin ${plugin.id}');
        }
        for (final capability in definition.provides) {
          if (!capability.accepts(plugin)) {
            throw StateError(
                '${plugin.id} does not implement ${capability.name}');
          }
          capabilities[capability.name] = plugin;
        }
      }
      return built;
    } catch (_) {
      for (final plugin in built.reversed) {
        try {
          plugin.closeSession();
        } catch (_) {/* Preserve factory error. */}
      }
      rethrow;
    }
  }
}
