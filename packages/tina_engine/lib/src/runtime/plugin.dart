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
  /// The registration OWNS both registry membership and the optional
  /// [dispose] cleanup: disposal revokes membership first, then runs the
  /// cleanup, and the id becomes reusable only after the awaited disposal
  /// completes. Dual ownership, deliberately: the scope also keeps the same
  /// registration as its teardown backstop, so a plugin that drops the
  /// handle still tears down cleanly; [Registration.dispose] is idempotent
  /// with one shared completion future, so early release plus scope
  /// teardown (or a plain double release) runs the callback exactly once.
  ///
  /// Throws [StateError] naming the id and both plugin ids if [id] is
  /// already taken (and not disposed) in the same scope, or if the scope has
  /// stopped admitting registrations.
  Registration register(
    Object contribution, {
    required String id,
    FutureOr<void> Function()? dispose,
  }) {
    return scope.registerContribution(
      pluginId: plugin.id,
      contribution: contribution,
      id: id,
      dispose: dispose,
    );
  }

  /// Creates a child scope of [scope].
  PluginScope child(String name) => scope.child(name);
}

/// Lifecycle of a scope: admission is open while [active], closes the
/// moment [stopping] begins (registration, provision, and child creation
/// all reject), and [disposed] is terminal.
enum ScopeLifecycleState { active, stopping, disposed }

/// One contribution a plugin registered in a scope.
class Contribution {
  /// Id of the contribution, unique among LIVE contributions in its scope.
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
///
/// Registrations are REVERSIBLE: each owns its registry membership (and any
/// cleanup), disposal revokes membership before running the cleanup, and a
/// released id may be reused once the awaited disposal completed. Teardown
/// removes owned services and contributions but never touches anything
/// borrowed from the parent scope.
class PluginScope {
  /// Name of the scope.
  final String name;

  final ScopeResources resources;
  final PluginScope? parent;
  final _services = <ServiceKey, Object>{};
  final _contributions = <Contribution>[];
  final _registrations = <String, Registration>{};
  ScopeLifecycleState _state = ScopeLifecycleState.active;

  PluginScope(this.name, {this.parent}) : resources = ScopeResources();

  /// Current lifecycle state of this scope.
  ScopeLifecycleState get state => _state;

  /// Whether the scope still admits registration, provisioning, and child
  /// creation. Closes the moment stopping starts.
  bool get isAdmitting => _state == ScopeLifecycleState.active;

  void _assertAdmitting(String what) {
    if (isAdmitting) return;
    throw StateError(
      'Scope $name is ${_state.name}; cannot $what',
    );
  }

  /// Looks up one service by key, falling back to the parent scope. A
  /// disposed scope resolves nothing of its own (and cannot reach its
  /// parent's borrowed services through a dead scope: lookup throws).
  T? lookup<T>(ServiceKey<T> key) {
    if (_state == ScopeLifecycleState.disposed) {
      throw StateError('Scope $name is disposed; cannot look up $key');
    }
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
    _assertAdmitting('provide $key');
    final existing = _services[key];
    if (!replace && existing != null) {
      throw StateError(
        'Service $key is already provided in scope $name; '
        'pass replace: true to replace it',
      );
    }
    _services[key] = instance;
  }

  /// Adds one contribution with its owning registration; duplicate ids among
  /// LIVE contributions in this scope throw [StateError].
  ///
  /// Visible to the runtime for activation-time wiring; application code
  /// goes through [PluginContext.register], which builds the registration
  /// and its membership/cleanup ownership in one step.
  void addContribution(Contribution contribution, Registration registration) {
    _assertAdmitting('register contribution ${contribution.id}');
    final existing = _registrations[contribution.id];
    if (existing != null) {
      // A released-but-still-cleaning-up registration keeps its id
      // RESERVED: reusing the id inside that gap succeeds here, then the
      // old cleanup's revoke (by identity — see below) would delete the
      // replacement's membership while it stays live. Reject instead; the
      // caller retries once the old disposal completes.
      if (!existing.isDisposalComplete) {
        throw StateError(
          'Contribution id ${contribution.id} is still disposing in scope '
          '$name; the id is reserved until the old disposal completes',
        );
      }
      if (!existing.isDisposed) {
        final live = _byId(contribution.id);
        throw StateError(
          'Contribution id ${contribution.id} is already registered in '
          'scope $name by plugin ${live?.pluginId ?? "?"}; rejected plugin '
          '${contribution.pluginId}',
        );
      }
    }
    // Membership revocation is owned by the registration: the moment
    // disposal begins (early release OR scope teardown), the contribution
    // leaves the registry — before the cleanup runs. Revocation matches by
    // IDENTITY, not by id string: a dispose-then-reuse of the same id must
    // never let the old cleanup revoke the new registration's membership
    // (Fix: by-id revocation deleted the replacement).
    registration.onDisposeStart(() {
      _contributions.remove(contribution);
      if (identical(_registrations[contribution.id], registration)) {
        _registrations.remove(contribution.id);
      }
    });
    _contributions.add(contribution);
    _registrations[contribution.id] = registration;
    // Scope teardown backstop: the SAME idempotent registration, so early
    // release plus teardown runs the cleanup exactly once.
    resources.own(registration.dispose);
  }

  /// Builds the registration, adds the contribution, and hands back the
  /// handle — the one reversible-registration entry point.
  Registration registerContribution({
    required String pluginId,
    required Object contribution,
    required String id,
    FutureOr<void> Function()? dispose,
  }) {
    final registration = Registration.create(id, dispose);
    addContribution(
      Contribution(
        id: id,
        pluginId: pluginId,
        contribution: contribution,
        dispose: dispose,
      ),
      registration,
    );
    return registration;
  }

  /// Removes one service binding from this scope. Teardown-only helper: a
  /// disposed scope must not resolve a released service. Borrowed (parent)
  /// services are never touched — they stay with their owner.
  void removeService(ServiceKey key) => _services.remove(key);

  Contribution? _byId(String id) {
    for (final c in _contributions) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// All LIVE contributions registered in this scope, in registration
  /// order. Revoked contributions are gone from the list the moment their
  /// disposal begins.
  List<Contribution> get contributions => List.unmodifiable(_contributions);

  /// Creates a child scope that inherits services from this one. Rejected
  /// once stopping starts.
  PluginScope child(String name) {
    _assertAdmitting('create child scope $name');
    return PluginScope(name, parent: this);
  }

  /// Tears the scope down: children of children are NOT handled here (the
  /// runtime drives those); this scope closes admission, then drains
  /// contributions and resources in reverse acquisition order, removing
  /// owned services as each drains. Parent-owned (borrowed) resources are
  /// never disposed. Idempotent: every caller shares one completion future.
  Future<void> dispose() {
    if (_state == ScopeLifecycleState.disposed) return resources.dispose();
    _state = ScopeLifecycleState.stopping;
    return resources.dispose().whenComplete(() {
      // Owned services leave the registry; borrowed parent bindings are
      // untouched (they were never in _services).
      _services.clear();
      _state = ScopeLifecycleState.disposed;
    });
  }
}
