import 'dart:async';

/// Releases owned resources in reverse acquisition order, even if one fails.
/// Register only owned resources; borrowed dependencies stay with their owner.
class RuntimeResources {
  final _cleanup = <FutureOr<void> Function()>[];
  Future<void>? _closing;

  void own(FutureOr<void> Function() cleanup) {
    if (_closing != null) throw StateError('Runtime is closing');
    _cleanup.add(cleanup);
  }

  bool get isClosing => _closing != null;

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
