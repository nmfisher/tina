import 'process_tree.dart';

/// Process-global registry of tool-spawned subprocesses so they can be reaped
/// when tina exits.
///
/// Reaping is **on by default**: a process the agent backgrounded (e.g.
/// `npm run dev &`) dies with the session instead of leaking past cancel,
/// timeout, or `/exit`. This is intentional — tina owns the processes its
/// tools spawn. The tradeoff is that a process you *mean* to detach and survive
/// tina is also killed; that's an unusual case and not the model's default.
///
/// [IoProcessRunner] registers a pid on spawn and unregisters it when the
/// process exits, so the registry only ever holds still-running children — i.e.
/// exactly the leaks we want to clean up. Call [reapAll] from the exit funnel
/// and the SIGTERM/SIGHUP handlers.
class ChildProcessRegistry {
  ChildProcessRegistry._();
  static final ChildProcessRegistry instance = ChildProcessRegistry._();

  final Set<int> _pids = {};

  /// Register a live subprocess pid. No-op for non-positive pids.
  void track(int pid) {
    if (pid > 0) _pids.add(pid);
  }

  /// Remove a pid once its process has exited. No-op if not tracked.
  void untrack(int pid) {
    _pids.remove(pid);
  }

  /// Whether [pid] is currently tracked. Test/inspection aid.
  bool isTracking(int pid) => _pids.contains(pid);

  /// Best-effort tree-kill of every still-tracked pid, then clear the set.
  /// Idempotent and safe on any exit path. Uses a short [grace] so shutdown
  /// stays snappy.
  Future<void> reapAll({
    Duration grace = const Duration(seconds: 1),
  }) async {
    final pids = _pids.toList();
    _pids.clear();
    await Future.wait(pids.map((p) => killProcessTree(p, grace: grace)));
  }
}
