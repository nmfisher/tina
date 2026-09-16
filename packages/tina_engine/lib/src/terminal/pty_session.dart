import 'dart:async';

/// Signals all live members of one owned session; returns the live count.
/// Signal zero only probes. Implementations exclude zombies and must surface
/// enumeration/permission failures rather than treating them as an empty tree.
typedef SessionSignal = int Function(int signal);

/// Awaited TERM → grace → KILL lifecycle, independent of PTY I/O and isolates.
/// A clock and delay are injectable so deadlines can be tested without sleeps.
class PtySession {
  final SessionSignal signal;
  final Duration Function() now;
  final Future<void> Function(Duration) delay;

  PtySession(
      {required this.signal,
      Duration Function()? now,
      Future<void> Function(Duration)? delay})
      : now = now ?? (Stopwatch()..start()).elapsedTime,
        delay = delay ?? Future<void>.delayed;

  Future<void> terminate({required Duration grace}) async {
    if (signal(15) == 0) return;
    final deadline = now() + grace;
    const interval = Duration(milliseconds: 20);
    while (now() < deadline) {
      if (signal(0) == 0) return;
      final remaining = deadline - now();
      await delay(remaining < interval ? remaining : interval);
    }
    // Re-enumerate on every pass: this includes children forked during grace
    // and descendants whose original group leader has already exited.
    final killDeadline = now() + const Duration(seconds: 1);
    while (signal(9) != 0) {
      if (now() >= killDeadline) {
        throw StateError('PTY session still has live processes after SIGKILL');
      }
      await delay(interval);
    }
  }
}

extension on Stopwatch {
  Duration elapsedTime() => elapsed;
}
