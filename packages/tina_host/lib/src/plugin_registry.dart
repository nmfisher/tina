import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';
import 'plugin_definition.dart';

typedef PluginFactory<C> = AgentPlugin Function(C context);

/// Application catalog. Only its constructor may register first-party names.
/// Dependency graphs are validated before any factory is called.
final class PluginRegistry<C> {
  PluginRegistry(
      {List<PluginDefinition<C>> definitions = const [],
      this.requiredCapabilities = const []}) {
    for (final definition in definitions) {
      if (!definition.id.startsWith('tina/')) {
        throw ArgumentError(
            'first-party plugin must use tina/: ${definition.id}');
      }
      _add(definition);
    }
  }

  final List<PluginCapability<Object>> requiredCapabilities;

  final _definitions = <String, PluginDefinition<C>>{};

  void _add(PluginDefinition<C> definition) {
    validatePluginId(definition.id);
    for (final setting in definition.settings) {
      if (!setting.id.startsWith('${definition.id}/')) {
        throw ArgumentError('${definition.id} cannot declare ${setting.id}');
      }
    }
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

  void register(String id, PluginFactory<C> factory,
          {required String description,
          bool live = false,
          List<SettingDefinition<Object>> settings = const []}) =>
      registerDefinition(PluginDefinition(id, factory,
          description: description, live: live, settings: settings));

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

  /// Reasons why removing a selected provider would invalidate this profile.
  Map<String, List<String>> blockingReasons(Iterable<String> ids) {
    final selected = ids.toSet();
    final result = <String, List<String>>{};
    for (final id in selected) {
      final supplied = definition(id).provides.map((c) => c.name).toSet();
      final reasons = <String>[
        for (final role in requiredCapabilities)
          if (supplied.contains(role.name)) 'Application requires ${role.name}',
        for (final consumer in selected)
          if (consumer != id)
            for (final dependency in definition(consumer).requires)
              if (supplied.contains(dependency.name))
                '$consumer requires ${dependency.name}',
      ];
      if (reasons.isNotEmpty) result[id] = List.unmodifiable(reasons);
    }
    return Map.unmodifiable(result);
  }

  PluginSelection selection(Iterable<String> ids) {
    final selected = ids.toList();
    try {
      final ordered = orderedIds(selected);
      return PluginSelection(ordered, blockingReasons(ordered), const []);
    } on ArgumentError catch (error) {
      return PluginSelection(selected, const {}, [error.message.toString()]);
    }
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
    for (final capability in requiredCapabilities) {
      if (!providers.containsKey(capability.name))
        throw ArgumentError(
            'Application requires ${capability.name}; no provider selected');
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

final class PluginSelection {
  PluginSelection(List<String> selected, this.blockingReasons, this.errors)
      : selected = List.unmodifiable(selected);
  final List<String> selected;
  final Map<String, List<String>> blockingReasons;
  final List<String> errors;
  bool get valid => errors.isEmpty;
}
