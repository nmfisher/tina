import 'dart:async';

import 'contracts.dart';

export 'contracts.dart';

/// One provider's binding of a service to its instance.
///
/// Created by the scope at activation; the instance is the object the plugin
/// factory built for [key].
class ProvidedService {
  /// Typed identity of the service.
  final ServiceKey key;

  /// The live object exposed for [key].
  final Object instance;

  const ProvidedService(this.key, this.instance);

  @override
  String toString() => 'ProvidedService($key)';
}

/// Builds the plugin's root object from its resolved dependencies.
abstract interface class PluginFactory {
  /// Called once at activation with a context bound to one plugin.
  Object build(PluginContext context);
}

/// Function form of [PluginFactory] for inline plugins.
typedef PluginFactoryFn = Object Function(PluginContext context);

/// Wraps a [PluginFactoryFn] so it can be used as a [PluginFactory].
class FnPluginFactory implements PluginFactory {
  final PluginFactoryFn _fn;

  const FnPluginFactory(this._fn);

  @override
  Object build(PluginContext context) => _fn(context);
}

/// Static description of one plugin: what it needs, what it contributes.
class PluginDescriptor {
  /// Unique id of the plugin within its runtime.
  final String id;

  /// Services that must be resolvable before [factory] runs.
  final Set<ServiceKey> requires;

  /// Singleton bindings the plugin contributes. More than one key means the
  /// plugin contributes several singleton bindings.
  final List<ServiceKey> provides;

  /// Decodes the plugin's config block; null means the plugin takes no config.
  final PluginConfigDecoder<Object?>? decodeConfig;

  /// Builds the plugin's root object.
  final PluginFactory factory;

  const PluginDescriptor({
    required this.id,
    this.requires = const <ServiceKey>{},
    this.provides = const <ServiceKey>[],
    this.decodeConfig,
    required this.factory,
  });

  @override
  String toString() => 'PluginDescriptor($id)';
}

/// What one plugin sees while its factory runs.
class PluginContext {
  /// Descriptor of the plugin being activated.
  final PluginDescriptor plugin;

  /// Scope the plugin is activating in.
  final PluginScope scope;

  const PluginContext({required this.plugin, required this.scope});

  /// Resolves a declared dependency through the scope.
  ///
  /// Throws [StateError] naming the plugin id and the key if absent.
  T require<T>(ServiceKey<T> key) {
    final value = scope.lookup<T>(key);
    if (value == null) {
      throw StateError(
        'Plugin ${plugin.id} requires $key but it is not provided in scope '
        '${scope.name}',
      );
    }
    return value;
  }

  /// Registers an owned resource with the scope.
  ///
  /// The scope owns [cleanup]: teardown releases it in reverse acquisition
  /// order, exactly once. There is no per-caller handle; borrowed resources
  /// must not be registered here.
  void own(FutureOr<void> Function() cleanup) {
    scope.resources.own(cleanup);
  }

  /// Registers one contribution (tool, command, contributor) under [id] in the
  /// scope's contribution registry and returns its [Registration] handle.
  ///
  /// Dual ownership, deliberately: the scope owns [dispose] — teardown
  /// releases the contribution exactly once, in reverse acquisition order,
  /// and remains the backstop so a plugin that drops the returned handle
  /// still tears down cleanly. The returned handle is only for releasing
  /// early; [Registration.dispose] is idempotent, so releasing through it and
  /// again at scope teardown (or a plain double release) is safe.
  ///
  /// Throws [StateError] naming the id and both plugin ids if [id] is already
  /// taken in the same scope.
  Registration register(
    Object contribution, {
    required String id,
    FutureOr<void> Function()? dispose,
  }) {
    scope.addContribution(
      Contribution(
        id: id,
        pluginId: plugin.id,
        contribution: contribution,
        dispose: dispose,
      ),
    );
    final registration = Registration.create(id, dispose);
    if (dispose != null) {
      // The scope keeps the same Registration as its backstop: teardown calls
      // the idempotent dispose, so releasing early through the returned
      // handle and again at scope teardown runs the callback exactly once.
      scope.resources.own(registration.dispose);
    }
    return registration;
  }

  /// Creates a child scope of [scope].
  PluginScope child(String name) => scope.child(name);
}

/// One contribution a plugin registered in a scope.
class Contribution {
  /// Id of the contribution, unique within its scope.
  final String id;

  /// Id of the plugin that registered it.
  final String pluginId;

  /// The contributed object (tool, command, contributor, ...).
  final Object contribution;

  /// Optional cleanup for the contribution; owned by the scope's resources,
  /// so scope teardown releases the contribution exactly once.
  final FutureOr<void> Function()? dispose;

  const Contribution({
    required this.id,
    required this.pluginId,
    required this.contribution,
    this.dispose,
  });

  @override
  String toString() => 'Contribution($id by $pluginId)';
}

/// Activation-time view of one plugin's services and contributions.
class PluginScope {
  /// Name of the scope.
  final String name;

  final ScopeResources resources;
  final PluginScope? parent;
  final _services = <ServiceKey, Object>{};
  final _contributions = <Contribution>[];
  final _contributionIds = <String>{};

  PluginScope(this.name, {this.parent}) : resources = ScopeResources();

  /// Looks up one service by key, falling back to the parent scope.
  T? lookup<T>(ServiceKey<T> key) {
    final value = _services[key];
    if (value != null) return value as T;
    return parent?.lookup<T>(key);
  }

  /// Binds one service.
  ///
  /// Without [replace], binding a key that is already bound in this scope
  /// throws [StateError] naming the key and the scope; replacement is an
  /// explicit decision. Keys inherited from the parent scope are shadowed
  /// silently — that is lookup fallback, not replacement.
  void provide(ServiceKey key, Object instance, {bool replace = false}) {
    final existing = _services[key];
    if (!replace && existing != null) {
      throw StateError(
        'Service $key is already provided in scope $name; '
        'pass replace: true to replace it',
      );
    }
    _services[key] = instance;
  }

  /// Adds one contribution; duplicate ids in this scope throw [StateError].
  void addContribution(Contribution contribution) {
    if (!_contributionIds.add(contribution.id)) {
      final existing = _byId(contribution.id);
      throw StateError(
        'Contribution id ${contribution.id} is already registered in scope '
        '$name by plugin ${existing?.pluginId ?? "?"}; rejected plugin '
        '${contribution.pluginId}',
      );
    }
    _contributions.add(contribution);
  }

  Contribution? _byId(String id) {
    for (final c in _contributions) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// All contributions registered in this scope, in registration order.
  List<Contribution> get contributions => List.unmodifiable(_contributions);

  /// Creates a child scope that inherits services from this one.
  PluginScope child(String name) => PluginScope(name, parent: this);
}
