import 'dart:async';

/// Process-global cap on sub-agent nesting depth and concurrent live agents.
///
/// Created ONCE at the app's composition root and injected into every
/// [SubAgentScheduler], so the caps apply across all schedulers/sessions in the
/// process rather than per-scheduler. Keeping the cap here (not on the
/// scheduler) means a second scheduler constructed in the same process shares
/// the same live-agent count and the same depth ceiling.
class AgentQuota {
  /// Maximum nesting depth. 0-based: the root orchestrator and its direct
  /// children are depth 0, their children depth 1, and so on. A spawn at
  /// [maxDepth] or deeper is rejected. `<= 0` means UNBOUNDED (tin-y9k2:
  /// `--yolo` lifts the cap; 0-as-reject-everything was never useful).
  final int maxDepth;

  /// Maximum number of agents that may run concurrently at once (the running
  /// slot count). Workflows never hold a slot, so they don't count here. Queued
  /// jobs are unbounded — excess spawns wait for a free slot rather than being
  /// rejected. `<= 0` means unbounded (no semaphore cap).
  final int maxLive;

  final _Semaphore _sem;

  AgentQuota({this.maxDepth = 3, this.maxLive = 3})
      : _sem = _Semaphore(maxLive > 0 ? maxLive : null);

  /// True when a spawn at [depth] is allowed.
  bool allowsDepth(int depth) => maxDepth <= 0 || depth < maxDepth;

  /// Take a running slot. Completes immediately when one is free, otherwise
  /// when a previous holder releases.
  Future<void> acquire() => _sem.acquire();

  /// Return a running slot to the pool.
  void release() => _sem.release();
}

/// Minimal counting semaphore for capping live sub-agents. Moved out of
/// [SubAgentScheduler] so the cap it guards can be shared process-wide via
/// [AgentQuota]. A null cap disables it: every [acquire] completes
/// immediately.
class _Semaphore {
  final int? max;
  int _holders = 0;
  final List<Completer<void>> _waiters = [];

  _Semaphore(this.max);

  Future<void> acquire() {
    final cap = max;
    if (cap == null || _holders < cap) {
      _holders++;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      // Hand the freed slot straight to the next waiter.
      _waiters.removeAt(0).complete();
    } else {
      _holders--;
    }
  }
}
