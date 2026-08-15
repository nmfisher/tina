import 'dart:async';

/// Serializes the TUI's attention-taking modals — human gates, permission
/// prompts, loop-budget confirms — onto ONE queue per TUI, so two background
/// workflow runs never race on `editor.readKey()` (whoever lost the race
/// would swallow the other's key). `ask_user` (the main agent, mid-turn)
/// stays off the queue: one turn at a time per conversation already makes it
/// exclusive by construction.
///
/// `run` returns the modal's own result. While a modal is open, a newly
/// queued one fires its [onQueued] callback immediately (the run panel
/// shows a "waiting for your input" notice, so the queue is visible instead
/// of silent). A modal that throws completes the caller's future with the
/// error but never breaks the chain — the next queued modal still runs.
class AttentionQueue {
  Future<void> _tail = Future.value();

  /// A modal is currently holding the keyboard.
  bool get active => _active;
  bool _active = false;

  Future<T> run<T>(Future<T> Function() modal, {void Function()? onQueued}) {
    final done = Completer<T>();
    final queuedBehind = _active;
    if (queuedBehind) onQueued?.call();
    // Claim synchronously, so `active` (and a racing enqueue's queuedBehind
    // check) see the modal as already open — the chained callback below runs
    // as a microtask, too late for a same-tick caller.
    _active = true;
    _tail = _tail.then((_) async {
      _active = true;
      try {
        final result = await modal();
        if (!done.isCompleted) done.complete(result);
      } catch (e, s) {
        if (!done.isCompleted) done.completeError(e, s);
      } finally {
        _active = false;
      }
    });
    return done.future;
  }
}
