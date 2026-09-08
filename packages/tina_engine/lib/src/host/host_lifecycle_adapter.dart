import '../agent/run_lifecycle.dart';

/// Activity is derived from all active identities, not the last run to finish.
/// The derived value is emitted only when it changes: nested scopes share one
/// host (a turn slot wraps Agent.run; panels wrap sub-agents), so per-identity
/// events would re-fire an already-true cue when an inner scope completes
/// while an outer one is still active (tin-y4qn).
mixin HostLifecycleAdapter implements RunLifecycleSink {
  final Set<Object> _activeRuns = {};
  bool _emittedActivity = false;
  bool get hasActiveRuns => _activeRuns.isNotEmpty;
  void setActivity(bool active);
  @override
  void runStarted(Object identity) {
    if (_activeRuns.add(identity) && !_emittedActivity) {
      _emittedActivity = true;
      setActivity(true);
    }
  }

  @override
  void runCompleted(Object identity) {
    if (_activeRuns.remove(identity) &&
        _emittedActivity &&
        _activeRuns.isEmpty) {
      _emittedActivity = false;
      setActivity(false);
    }
  }
}
