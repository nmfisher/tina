import 'dart:async';

/// Namespaced, typed identity for one service.
///
/// Two keys with the same [id] name the same service, no matter where they
/// were created; the type parameter only documents what the service exposes.
final class ServiceKey<T> {
  /// Stable identifier of the service within its namespace.
  final String id;

  const ServiceKey(this.id);

  @override
  String toString() => 'ServiceKey<$T>($id)';

  @override
  bool operator ==(Object other) => other is ServiceKey && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Decodes one plugin's config block into its typed config object.
///
/// Implementations throw [PluginConfigException] on bad input.
typedef PluginConfigDecoder<T> = T Function(Map<String, Object?> raw);

/// Thrown by a [PluginConfigDecoder] when a config block is invalid.
class PluginConfigException implements Exception {
  /// Id of the plugin whose config failed to decode.
  final String pluginId;

  /// Human-readable description of what was wrong with the config.
  final String message;

  const PluginConfigException(this.pluginId, this.message);

  @override
  String toString() => 'PluginConfigException: plugin $pluginId: $message';
}

/// Lifecycle of one plugin, from creation to disposal.
enum PluginLifecycleState {
  /// Created but not yet activated.
  pending,

  /// Dependencies are being resolved and the factory is about to run.
  activating,

  /// The factory finished; services and contributions are bound.
  active,

  /// Disposal started; owned resources are being released.
  stopping,

  /// All resources are released.
  disposed,
}

/// Handle for one owned resource; disposing is idempotent.
class Registration {
  /// Name of the resource, used in error messages.
  final String id;

  final FutureOr<void> Function()? _dispose;
  bool _disposed = false;
  Future<void>? _disposedFuture;

  Registration._(this.id, this._dispose);

  /// Creates a registration that runs [onDispose] at most once.
  factory Registration.create(String id, FutureOr<void> Function()? onDispose) =>
      Registration._(id, onDispose);

  /// Runs the dispose callback once; later calls are no-ops that return the
  /// same future.
  Future<void> dispose() {
    if (_disposed) return _disposedFuture!;
    _disposed = true;
    final onDispose = _dispose;
    return _disposedFuture = onDispose == null
        ? Future<void>.value()
        : Future<void>.microtask(onDispose);
  }
}

/// One cleanup implementation for every plugin scope.
///
/// Releases owned resources in reverse acquisition order, even if one fails.
/// Register only owned resources; borrowed dependencies stay with their owner.
class ScopeResources {
  final _cleanup = <FutureOr<void> Function()>[];
  Future<void>? _closing;

  /// Appends one cleanup; throws [StateError] once dispose has started.
  void own(FutureOr<void> Function() cleanup) {
    if (_closing != null) throw StateError('Runtime is closing');
    _cleanup.add(cleanup);
  }

  /// Whether dispose has started; no further resources can be owned.
  bool get isClosing => _closing != null;

  /// Runs cleanups in reverse order, continues after each error, and rethrows
  /// the first error with its original stack trace. Memoized: a second call
  /// returns the same future.
  Future<void> dispose() => _closing ??= Future<void>.microtask(() async {
    Object? error;
    StackTrace? stack;
    for (final cleanup in _cleanup.reversed) {
      try {
        await cleanup();
      } catch (e, st) {
        error ??= e;
        stack ??= st;
      }
    }
    _cleanup.clear();
    if (error != null) Error.throwWithStackTrace(error, stack!);
  });

  /// Retains a work failure if cleanup also fails.
  Future<T> run<T>(Future<T> Function() body) async {
    var failed = false;
    try {
      return await body();
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      try {
        await dispose();
      } catch (_) {
        if (!failed) rethrow;
      }
    }
  }
}
