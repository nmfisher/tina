import 'dart:async';

/// A session-wide coordination gate that pauses every agent when any one trips
/// its per-session token limit, then resumes them on a user decision.
///
/// Flow: an agent whose [TokenBudget] per-session limit is crossed calls
/// [requestPause]; the gate closes and emits `reason` on [onPause] (which the
/// TUI listens for to show a "limit reached — continue / abort" dialog). Every
/// other agent is parked because each [MeteringProvider] awaits
/// [waitForResume] before its next provider request — that's how "pause all
/// agents" works from a single shared gate. The dialog calls [resume] with the
/// user's decision; waiters resolve and agents either resume their turn
/// (continue) or abort it (Esc).
///
/// Sibling to [SpendLedger] on `AppComposition`. One per app session.
class PauseGate {
  bool _paused = false;
  String? _reason;
  final StreamController<String> _pauseEvents =
      StreamController<String>.broadcast();
  // Waiters parked in waitForResume while paused. Each resolves with the
  // continue/abort decision from resume().
  final List<Completer<bool>> _waiters = [];

  /// True between [requestPause] and the next [resume].
  bool get isPaused => _paused;

  /// The reason from the first tripper, while paused.
  String? get reason => _reason;

  /// Fires `reason` exactly once per pause transition (idempotent
  /// [requestPause] ⇒ no double emit). The TUI subscribes to show the dialog.
  Stream<String> get onPause => _pauseEvents.stream;

  /// Close the gate. Idempotent: a no-op if already paused, so two agents
  /// tripping near-simultaneously produce one event (and the first tripper's
  /// reason wins).
  void requestPause(String reason) {
    if (_paused) return;
    _paused = true;
    _reason = reason;
    if (!_pauseEvents.isClosed) _pauseEvents.add(reason);
  }

  /// Returns `true` immediately when not paused. Otherwise blocks until
  /// [resume]; the returned bool is the continue (`true`) / abort (`false`)
  /// decision. [cancelSignal] races the wait so a tear-down (ESC-exit, session
  /// cancel) returns `false` promptly without consuming a resume — mirroring
  /// `SpendLedger.acquireRequestSlot`'s cancel-race.
  ///
  /// Two callers: `MeteringProvider` ignores the bool (it only needs to block
  /// while paused); the tripping `Agent` consumes it to continue-vs-abort.
  Future<bool> waitForResume({Future<void>? cancelSignal}) {
    if (!_paused) return Future.value(true);
    final c = Completer<bool>();
    _waiters.add(c);
    if (cancelSignal != null) {
      cancelSignal.then((_) {
        // Remove so a later resume() can't double-complete this waiter.
        _waiters.remove(c);
        if (!c.isCompleted) c.complete(false);
      });
    }
    return c.future;
  }

  /// Open the gate and resolve every waiter with [continueDecision]. No-op when
  /// not paused.
  void resume({required bool continueDecision}) {
    if (!_paused) return;
    _paused = false;
    _reason = null;
    final waiters = List.of(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) w.complete(continueDecision);
    }
  }

  /// Close the event stream (app teardown / tests).
  Future<void> dispose() async => await _pauseEvents.close();
}
