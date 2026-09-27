/// The locator. Deliberately minimal — this is the whole API.
///
/// The rules it will not break:
///
/// - register by type, get by type; **a missing service throws, and the
///   message names the type** — never a null to chase.
/// - **no factories, no lazy construction, no scanning.** Those are what
///   turned the old engine's registry into a framework.
/// - **resolve at use, not at construction**: [Services.get] reads the
///   live map, so registration order never matters — a plugin may hold
///   the locator before the thing it needs is registered.
/// - one locator per session; **never passed into a turn** — plugins hold
///   it, and [TurnContext] stays clean. The loop never learns it exists.
library;

/// The service locator. One per session.
final class Services {
  final Map<Type, Object> _byType = {};

  /// Register [instance] under its runtime type. Re-registering the same
  /// type replaces the previous instance — the locator is a mutable
  /// session truth, not a freeze. Returns the locator so registration
  /// lines read like a sentence.
  T put<T>(T instance) {
    _byType[T] = instance!;
    return instance;
  }

  /// The registered instance of type `T`.
  ///
  /// Throws [StateError] when nothing is registered — the message names
  /// the type, because a bare "not found" sends the reader hunting.
  T get<T>() {
    final s = _byType[T];
    if (s == null) {
      throw StateError(
          'no service registered for type $T — register it before use');
    }
    return s as T;
  }

  /// The registered instance of type `T`, or null.
  T? maybe<T>() => _byType[T] as T?;
}
