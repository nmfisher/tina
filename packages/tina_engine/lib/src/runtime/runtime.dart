import 'dart:async';

import 'package:logging/logging.dart';

import 'plugin.dart';

final _log = Logger('tina.runtime');

/// Composition failure of a plugin set.
///
/// Thrown only for problems detected while composing a [PluginRuntime]:
/// duplicate ids, missing dependencies, cycles, colliding providers, bad
/// config, or a factory that failed. Never thrown for tool or policy
/// failures.
class PluginCompositionError implements Exception {
  /// What went wrong, in one short sentence.
  final String problem;

  /// Id of the plugin the problem is about.
  final String pluginId;

  /// Dependency chain of plugin ids leading to the problem; empty when no
  /// chain applies.
  final List<String> chain;

  const PluginCompositionError(
    this.problem, {
    required this.pluginId,
    this.chain = const <String>[],
  });

  @override
  String toString() {
    final buffer = StringBuffer('PluginCompositionError: $problem')
      ..write(' (plugin: $pluginId');
    if (chain.isNotEmpty) buffer.write('; chain: ${chain.join(' -> ')}');
    buffer.write(')');
    return buffer.toString();
  }
}

/// Immutable diagnostics for one plugin, derived from its descriptor and its
/// lifecycle state at describe() time.
///
/// Plain data only. Service keys appear as their `.id` strings (declared
/// order), never as key instances, and config is skipped entirely —
/// diagnostics never materialize keys merely to render them.
class PluginDescription {
  /// Id of the described plugin.
  final String id;

  /// Lifecycle state when the description was taken.
  final PluginLifecycleState state;

  /// Ids of the service keys the plugin provides, in declared order.
  final List<String> provides;

  /// Ids of the service keys the plugin requires, in declared order.
  final List<String> requires;

  /// Ids of the runtime plugins this plugin depends on through its requires
  /// keys, sorted ascending. Resolution follows activation's rules: a key
  /// with a single runtime provider yields that provider; a key whose
  /// selected provider is another plugin yields the selection; a key
  /// satisfied only through the parent scope, and a multi-provider key whose
  /// selected provider is not resolvable, yield no edge.
  final List<String> dependsOn;

  const PluginDescription({
    required this.id,
    required this.state,
    this.provides = const <String>[],
    this.requires = const <String>[],
    this.dependsOn = const <String>[],
  });

  @override
  String toString() =>
      'plugin(id: $id, state: ${state.name}, '
      'provides: [${provides.join(', ')}], '
      'requires: [${requires.join(', ')}], '
      'dependsOn: [${dependsOn.join(', ')}])';
}

/// Immutable diagnostics for a whole runtime: one [PluginDescription] per
/// plugin (id-ascending) plus the activation order. Safe to take before
/// activation — see [PluginRuntime.describe].
class RuntimeDescription {
  /// Name of the runtime.
  final String name;

  /// Per-plugin descriptions, id-ascending.
  final List<PluginDescription> plugins;

  /// Plugin ids in activation order; empty before activation. A frozen copy
  /// of the runtime's real activation data.
  final List<String> activationOrder;

  const RuntimeDescription({
    required this.name,
    this.plugins = const <PluginDescription>[],
    this.activationOrder = const <String>[],
  });

  @override
  String toString() {
    final buffer = StringBuffer('runtime($name):');
    for (final plugin in plugins) {
      buffer
        ..write('\n')
        ..write(plugin.toString());
    }
    return buffer.toString();
  }
}

/// Root scope that reports every child scope created from it, directly or
/// transitively, so the runtime can dispose children before parents.
final class _RuntimeScope extends PluginScope {
  final _children = <PluginScope>[];

  _RuntimeScope(super.name, {super.parent});

  @override
  PluginScope child(String name) {
    final child = _RuntimeScope(name, parent: this);
    _children.add(child);
    return child;
  }
}

/// Activates a set of plugins into one root scope and tears it down.
///
/// Activation validates the plugin set before any factory runs, then builds
/// plugins in dependency order. Disposal is the mirror image: children and
/// consumers first, providers last.
class PluginRuntime {
  /// Name of the runtime and of its root scope.
  final String name;

  /// Plugins this runtime owns, ordered by id.
  final List<PluginDescriptor> plugins;

  /// Raw config for plugins that declare a decoder, keyed by plugin id: each
  /// plugin's decoder receives only its own block (or an empty map when the
  /// config has no entry for it), never another plugin's or the whole map.
  final Map<String, Object?> config;

  /// Root scope the runtime owns; its name is [name].
  final PluginScope scope;

  final _states = <String, PluginLifecycleState>{};
  final _selections = <String, String>{}; // service key id -> plugin id
  final _configs = <String, Object?>{};
  final _activationOrder = <String>[];
  bool _activationStarted = false;
  bool _failed = false;
  Future<void>? _disposed;

  /// Builds a runtime around a fresh root scope.
  PluginRuntime({
    required String name,
    required List<PluginDescriptor> plugins,
    this.config = const {},
    PluginScope? parent,
  })  : name = name,
        plugins = List.unmodifiable(plugins),
        scope = _RuntimeScope(name, parent: parent) {
    for (final plugin in plugins) {
      _states[plugin.id] = PluginLifecycleState.pending;
    }
  }

  /// Marks [pluginId] as the explicit provider of every key it declares.
  ///
  /// A selected plugin does not collide with another provider of the same
  /// key during validation; the selection wins and the other provider skips
  /// binding that key. At most one selection per key. Call before
  /// [activate].
  void select(String pluginId) {
    if (_activationStarted) {
      throw StateError('select() must be called before activate()');
    }
    PluginDescriptor? descriptor;
    for (final plugin in plugins) {
      if (plugin.id == pluginId) descriptor = plugin;
    }
    if (descriptor == null) {
      throw ArgumentError('Unknown plugin id "$pluginId" in runtime $name');
    }
    for (final key in descriptor.provides) {
      final existing = _selections[key.id];
      if (existing != null && existing != pluginId) {
        throw PluginCompositionError(
          'service key $key already has selected provider "$existing"; '
          'cannot also select "$pluginId"',
          pluginId: pluginId,
        );
      }
      _selections[key.id] = pluginId;
    }
  }

  /// Validates the plugin set, then activates every plugin in dependency
  /// order.
  ///
  /// Validation rejects duplicate ids, missing dependencies, dependency
  /// cycles, colliding providers, and undecodable config before any factory
  /// runs. A failing factory rolls back the partial scope and rethrows a
  /// [PluginCompositionError] with the original stack trace. Services that
  /// come from the parent scope are borrowed, never stopped.
  ///
  /// Plugin factories are synchronous, so activation runs to completion
  /// synchronously; this async form stays for API stability. On failure the
  /// rollback disposal starts immediately (its errors are swallowed — see
  /// [_rollback]) and the composition error propagates without waiting for
  /// teardown to drain.
  Future<void> activate() async {
    activateSync();
  }

  /// Synchronous twin of [activate]: same validation, same activation path,
  /// same errors — plugin factories are synchronous, so activation is too.
  /// Usable from synchronous constructors (e.g. a tool scope building its
  /// registry at construction time).
  void activateSync() {
    _activateAll();
  }

  /// Validation pass shared by [activate] and [activateSync]: duplicate ids,
  /// provider selection, missing dependencies, cycles, config decoding, and
  /// the topological order — everything that must hold before any factory
  /// runs. Returns the computed data the build phase consumes.
  (List<PluginDescriptor>, Map<String, PluginDescriptor>,
      Map<String, List<PluginDescriptor>>, Map<String, Set<String>>,
      List<String>) _validate() {
    // Sorted by id: deterministic iteration everywhere below.
    final sorted = [...plugins]..sort((a, b) => a.id.compareTo(b.id));

    final byId = <String, PluginDescriptor>{};
    final providers = <String, List<PluginDescriptor>>{};
    for (final plugin in sorted) {
      if (byId.containsKey(plugin.id)) {
        throw PluginCompositionError(
          'duplicate plugin id "${plugin.id}"',
          pluginId: plugin.id,
        );
      }
      byId[plugin.id] = plugin;
      for (final key in plugin.provides) {
        (providers[key.id] ??= []).add(plugin);
      }
    }

    // Unique provider per key: single provider, or the selected one.
    final providerOf = <String, String>{};
    for (final entry in providers.entries) {
      if (entry.value.length == 1) {
        providerOf[entry.key] = entry.value.single.id;
        continue;
      }
      final selected = _selections[entry.key];
      if (selected == null || !entry.value.any((p) => p.id == selected)) {
        final ids = entry.value.map((p) => p.id).toList()..sort();
        throw PluginCompositionError(
          'service key "${entry.key}" is provided by plugins '
          '${ids.join(', ')}; select exactly one provider with select()',
          pluginId: ids.first,
          chain: ids.sublist(1),
        );
      }
      providerOf[entry.key] = selected;
    }

    // Missing dependencies: runtime providers first, then the parent chain.
    for (final plugin in sorted) {
      for (final key in plugin.requires) {
        final inRuntime = providerOf.containsKey(key.id);
        final inParent =
            scope.parent != null && scope.parent!.lookup(key) != null;
        if (!inRuntime && !inParent) {
          throw PluginCompositionError(
            'plugin ${plugin.id} requires $key but no selected plugin or '
            'parent scope provides it',
            pluginId: plugin.id,
          );
        }
      }
    }

    // Cycles over "requires a key only one plugin provides" edges.
    final dependencies = <String, Set<String>>{};
    for (final plugin in sorted) {
      final deps = <String>{};
      for (final key in plugin.requires) {
        final provider = providerOf[key.id];
        if (provider != null) deps.add(provider);
      }
      dependencies[plugin.id] = deps;
    }
    _assertNoCycles(dependencies);

    // Config: decode up front; a bad block aborts before activation. Each
    // decoder sees only its own plugin's config block.
    for (final plugin in sorted) {
      final decode = plugin.decodeConfig;
      if (decode == null) continue;
      final block = config[plugin.id];
      final raw =
          block is Map<String, Object?> ? block : const <String, Object?>{};
      try {
        _configs[plugin.id] = decode(raw);
      } on PluginConfigException catch (error) {
        throw PluginCompositionError(
          'invalid config for plugin ${plugin.id}: ${error.message}',
          pluginId: plugin.id,
        );
      }
    }

    // Deterministic topological order, ties by plugin id ascending.
    final order = _topologicalOrder(sorted, dependencies);
    return (sorted, byId, providers, dependencies, order);
  }

  /// Shared validation + activation body behind [activate] and
  /// [activateSync]. Synchronous end to end; [activate] wraps it and awaits
  /// the rollback on failure.
  void _activateAll() {
    final (sorted, byId, providers, dependencies, order) = _validate();

    // (c) Build and bind, dependency before dependent; `order` came from
    // _validate.
    for (final id in order) {
      final plugin = byId[id]!;
      _states[id] = PluginLifecycleState.activating;
      try {
        for (final key in plugin.requires) {
          if (scope.lookup(key) == null) {
            throw PluginCompositionError(
              'plugin ${plugin.id} requires $key but it is not provided in '
              'scope ${scope.name}',
              pluginId: plugin.id,
            );
          }
        }
        final context = PluginContext(plugin: plugin, scope: scope);
        final instance = plugin.factory.build(context);
        for (final key in plugin.provides) {
          final providersOfKey =
              providers[key.id] ?? const <PluginDescriptor>[];
          final shadowed =
              providersOfKey.length > 1 && _selections[key.id] != plugin.id;
          if (shadowed) continue; // the selected provider owns this key
          scope.provide(key, instance);
        }
      } on PluginCompositionError {
        // Rollback is awaited by the outer activate(); the detached start
        // here only keeps the failure path inside _activateAll synchronous.
        unawaited(_rollback());
        rethrow;
      } catch (error, stackTrace) {
        unawaited(_rollback());
        Error.throwWithStackTrace(
          PluginCompositionError(
            'plugin ${plugin.id} failed during activation: $error',
            pluginId: plugin.id,
            chain: _chainOf(id, dependencies),
          ),
          stackTrace,
        );
      }
      _states[id] = PluginLifecycleState.active;
      _activationOrder.add(id);
    }
  }

  /// Whether activation failed terminally. A failed runtime is unusable:
  /// its scope drained, its plugins report disposed, and `dispose()` is a
  /// no-op that completes when the rollback finished. Retrying startup
  /// means constructing a NEW runtime after this one has drained.
  bool get isFailed => _failed;

  /// Lifecycle state of one plugin.
  ///
  /// Throws [ArgumentError] for an id the runtime does not own.
  PluginLifecycleState stateOf(String pluginId) {
    final state = _states[pluginId];
    if (state == null) {
      throw ArgumentError('Unknown plugin id "$pluginId" in runtime $name');
    }
    return state;
  }

  /// Plugin ids in the order they were activated; frozen copy.
  List<String> get activationOrder => List.unmodifiable(_activationOrder);

  /// Decoded config per plugin id, for plugins that declare a decoder.
  /// Populated by [activate].
  Map<String, Object?> get decodedConfigs => Map.unmodifiable(_configs);

  /// Diagnostics snapshot: one [PluginDescription] per plugin (id-ascending)
  /// plus the activation order so far.
  ///
  /// Safe to call BEFORE activation: it derives everything from the
  /// descriptors and current state without activating, without looking up or
  /// constructing any service, and without mutating the runtime — no state
  /// changes, and the root scope is never touched. `dependsOn` follows the
  /// same provider resolution as activation (single provider wins; the
  /// selected provider wins; parent-scope satisfaction yields no edge; a
  /// multi-provider key resolved to another plugin yields no edge). Only key
  /// ID strings appear in the output — key instances and config VALUES never
  /// do, and config is skipped entirely: diagnostics never materialize keys
  /// merely to render them.
  RuntimeDescription describe() {
    // Same provider resolution as validation in _activateAll, but over id
    // strings only and without any validation errors (multi-provider keys
    // with no selection simply yield no edge).
    final providers = <String, List<String>>{};
    for (final plugin in plugins) {
      for (final key in plugin.provides) {
        (providers[key.id] ??= []).add(plugin.id);
      }
    }
    final providerOf = <String, String>{};
    for (final entry in providers.entries) {
      if (entry.value.length == 1) {
        providerOf[entry.key] = entry.value.single;
        continue;
      }
      final selected = _selections[entry.key];
      if (selected != null && entry.value.contains(selected)) {
        providerOf[entry.key] = selected;
      }
    }

    final described = [...plugins]..sort((a, b) => a.id.compareTo(b.id));
    return RuntimeDescription(
      name: name,
      plugins: [
        for (final plugin in described)
          PluginDescription(
            id: plugin.id,
            state: _states[plugin.id] ?? PluginLifecycleState.pending,
            provides: [for (final key in plugin.provides) key.id],
            requires: [for (final key in plugin.requires) key.id],
            dependsOn: _dependsOnOf(plugin, providerOf),
          ),
      ],
      activationOrder: List.unmodifiable(_activationOrder),
    );
  }

  /// Provider PLUGIN ids [plugin] depends on through its requires keys,
  /// sorted ascending. Parent-scope satisfaction and unselected
  /// multi-provider keys yield no edge — see [describe].
  List<String> _dependsOnOf(
    PluginDescriptor plugin,
    Map<String, String> providerOf,
  ) {
    final edges = <String>{};
    for (final key in plugin.requires) {
      final provider = providerOf[key.id];
      if (provider != null) edges.add(provider);
    }
    return List.unmodifiable(edges.toList()..sort());
  }

  /// Creates and tracks a child of the root scope.
  ///
  /// Tracked child scopes are disposed before the root on [dispose].
  PluginScope childScope(String name) => scope.child(name);

  /// Disposes every tracked child scope, then the root scope.
  ///
  /// Idempotent: a second call returns the first future. Children and
  /// consumers go before parents and providers; errors do not stop the
  /// teardown, and the first error is rethrown with its stack trace once
  /// every plugin reached the disposed state.
  Future<void> dispose() => _disposed ??= _disposeAll();

  Future<void> _disposeAll() async {
    Object? firstError;
    StackTrace? firstStack;
    for (final id in _states.keys) {
      _states[id] = PluginLifecycleState.stopping;
    }
    // Children before parents: reverse creation order.
    for (final child in _descendantScopes().reversed) {
      try {
        await child.resources.dispose();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
    }
    try {
      await scope.resources.dispose();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStack ??= stackTrace;
    }
    for (final id in _states.keys) {
      _states[id] = PluginLifecycleState.disposed;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }

  /// Rolls back a failed activation: children first, then the root scope.
  /// Errors during rollback are collected and logged, never masking the
  /// composition error. Terminal states are set as each scope drains so a
  /// failed runtime accurately reports disposed.
  Future<void> _rollback() async {
    Object? firstError;
    StackTrace? firstStack;
    for (final child in _descendantScopes().reversed) {
      try {
        await child.resources.dispose();
      } catch (e, st) {
        firstError ??= e;
        firstStack ??= st;
        // Teardown continues; the activation error is what propagates.
      }
    }
    try {
      await scope.resources.dispose();
    } catch (e, st) {
      firstError ??= e;
      firstStack ??= st;
    }
    for (final id in _states.keys) {
      _states[id] = PluginLifecycleState.disposed;
    }
    _logTeardownFailure('rollback', firstError, firstStack);
  }

  /// Diagnostics sink for teardown failures that must not mask the primary
  /// error (rollback during a failed activation). Logged, never thrown.
  void _logTeardownFailure(String phase, Object? error, StackTrace? stack) {
    if (error == null) return;
    _log.warning('runtime $name: $phase teardown failed (diagnostic only)',
        error, stack);
  }

  /// Every scope created from the root, in creation order.
  List<PluginScope> _descendantScopes() {
    final result = <PluginScope>[];
    void walk(PluginScope scope) {
      if (scope is! _RuntimeScope) return;
      for (final child in scope._children) {
        result.add(child);
        walk(child);
      }
    }

    walk(scope);
    return result;
  }

  /// Dependency chain of [pluginId]: its direct dependencies, sorted.
  List<String> _chainOf(
      String pluginId, Map<String, Set<String>> dependencies) {
    final chain = dependencies[pluginId]?.toList() ?? <String>[];
    return chain..sort();
  }

  /// Depth-first cycle check; reports the cycle path as a chain.
  void _assertNoCycles(Map<String, Set<String>> dependencies) {
    final visiting = <String>{};
    final visited = <String>{};
    final stack = <String>[];

    void visit(String id) {
      visiting.add(id);
      stack.add(id);
      for (final dependency in dependencies[id] ?? const <String>{}) {
        if (visiting.contains(dependency)) {
          final start = stack.indexOf(dependency);
          final cycle = [...stack.sublist(start), dependency];
          throw PluginCompositionError(
            'dependency cycle ${cycle.join(' -> ')}',
            pluginId: dependency,
            chain: cycle,
          );
        }
        if (!visited.contains(dependency)) visit(dependency);
      }
      stack.removeLast();
      visiting.remove(id);
      visited.add(id);
    }

    for (final id in dependencies.keys) {
      if (!visited.contains(id)) visit(id);
    }
  }

  /// Kahn's algorithm picking the smallest ready id each step.
  List<String> _topologicalOrder(
    List<PluginDescriptor> sorted,
    Map<String, Set<String>> dependencies,
  ) {
    final order = <String>[];
    final emitted = <String>{};
    while (order.length < sorted.length) {
      String? next;
      for (final plugin in sorted) {
        if (emitted.contains(plugin.id)) continue;
        final deps = dependencies[plugin.id] ?? const <String>{};
        if (deps.every(emitted.contains)) {
          next = plugin.id;
          break;
        }
      }
      if (next == null) {
        // Unreachable: cycles are rejected before ordering.
        throw StateError('Runtime $name: plugins cannot be ordered');
      }
      emitted.add(next);
      order.add(next);
    }
    return order;
  }
}
