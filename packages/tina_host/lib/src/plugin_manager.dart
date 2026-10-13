import 'package:tina_engine_2/tina_engine_2.dart';
import 'host.dart';
import 'plugin_registry.dart';

/// Applies validated plugin selections between turns. Configuration and UI types
/// belong to callers; optional activation callbacks manage frontend resources.
final class PluginManager<C> {
  PluginManager(
      {required this.host, required this.registry, required this.context})
      : _desired = host.plugins
            .where((p) => registry.ids.contains(p.id))
            .map((p) => p.id)
            .toSet() {
    host.onIdle = reconcile;
  }
  final Host host;
  final PluginRegistry<C> registry;
  final C context;
  Set<String> _desired;
  void Function(AgentPlugin)? onLoaded;
  void Function(AgentPlugin)? onUnloading;
  final _observers = <Object,
      ({
    void Function(AgentPlugin) loaded,
    void Function(AgentPlugin) unloading
  })>{};

  /// Each attachment releases its own lifecycle observation. A failed
  /// activation rolls back the views already attached to that new plugin.
  void Function() listen(
      {required void Function(AgentPlugin) loaded,
      required void Function(AgentPlugin) unloading}) {
    final owner = Object();
    _observers[owner] = (loaded: loaded, unloading: unloading);
    return () => _observers.remove(owner);
  }

  void _loaded(AgentPlugin plugin) {
    onLoaded?.call(plugin);
    final activated = <void Function(AgentPlugin)>[];
    try {
      for (final item in _observers.entries.toList()) {
        if (!_observers.containsKey(item.key)) continue;
        activated.add(item.value.unloading);
        item.value.loaded(plugin);
      }
    } catch (_) {
      for (final release in activated.reversed) {
        try {
          release(plugin);
        } catch (_) {}
      }
      try {
        onUnloading?.call(plugin);
      } catch (_) {}
      rethrow;
    }
  }

  void _unloading(AgentPlugin plugin) {
    Object? failure;
    for (final release in [
      if (onUnloading != null) onUnloading!,
      ..._observers.values.toList().map((item) => item.unloading)
    ]) {
      try {
        release(plugin);
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }

  String? lastError;
  bool waitingForIdle = false;

  Set<String> get desired => Set.unmodifiable(_desired);
  Set<String> get loaded => host.plugins
      .where((p) => registry.ids.contains(p.id))
      .map((p) => p.id)
      .toSet();
  Set<String> get pending =>
      {..._desired.difference(loaded), ...loaded.difference(_desired)};

  void select(Iterable<String> ids) {
    registry.validate(ids);
    _desired = ids.toSet();
    reconcile();
  }

  void reconcile() {
    lastError = null;
    waitingForIdle = host.busy;
    if (waitingForIdle) return;
    final current = loaded;
    final target = {...current};
    for (final id in {...current, ..._desired}) {
      if (!registry.definition(id).live) continue;
      if (_desired.contains(id)) {
        target.add(id);
      } else {
        target.remove(id);
      }
    }
    try {
      // Restart-only dependencies can hold a live consumer's change until restart.
      registry.validate(target);
      // Existing consumers retain constructor-injected capabilities. Rebinding
      // them to another provider requires restart, not a silent stale reference.
      Map<String, String> providers(Set<String> selection) => {
            for (final id in selection)
              for (final capability in registry.definition(id).provides)
                capability.name: id,
          };
      final before = providers(current), after = providers(target);
      for (final id in current.intersection(target)) {
        for (final dependency in registry.definition(id).requires) {
          if (before[dependency.name] != after[dependency.name]) {
            lastError = '$id needs dependency rebinding; restart required';
            return;
          }
        }
      }
      final retained = host.plugins.where((p) => target.contains(p.id));
      final additions =
          registry.build(target.toList(), context, existing: retained);
      final attached = <AgentPlugin>[];
      var attempted = 0;
      try {
        for (final plugin in additions) {
          attempted++;
          host.attachPlugin(plugin, activate: _loaded);
          attached.add(plugin);
        }
      } catch (_) {
        for (final plugin in attached.reversed) {
          try {
            host.detachPlugin(plugin.id, deactivate: _unloading);
          } catch (_) {}
        }
        for (final plugin in additions.skip(attempted)) {
          try {
            plugin.closeSession();
          } catch (_) {}
        }
        rethrow;
      }
      Object? cleanupFailure;
      for (final id in registry.orderedIds(current).reversed) {
        if (!target.contains(id)) {
          try {
            host.detachPlugin(id, deactivate: _unloading);
          } catch (e) {
            cleanupFailure ??= e;
          }
        }
      }
      if (cleanupFailure != null) throw cleanupFailure;
    } catch (e) {
      lastError = 'Live update failed: $e';
    }
  }
}
