/// Time abstraction so tests never depend on wall-clock time.
library;

/// Returns the current time in milliseconds since the epoch.
typedef Now = int Function();

/// The real system clock.
int systemNow() => DateTime.now().millisecondsSinceEpoch;

/// A manually-advancing clock for tests.
final class FakeClock implements Now {
  int _now;

  FakeClock([int seed = 0]) : _now = seed;

  @override
  int call() => _now;

  /// Advances time by [millis] and returns the new reading.
  int advance(int millis) => _now += millis;
}
