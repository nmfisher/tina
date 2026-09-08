import '../agent/run_lifecycle.dart';

/// Activity is derived from all active identities, not the last run to finish.
mixin HostLifecycleAdapter implements RunLifecycleSink {
  final Set<Object> _activeRuns = {};
  bool get hasActiveRuns => _activeRuns.isNotEmpty;
  void setActivity(bool active);
  @override
  void runStarted(Object identity) {
    // Nested producers (turn slot + Agent.run) start the same host's activity:
    // raise only on the empty→non-empty transition so the cue is not re-fired
    // mid-turn (tin-y4qn busy-cue race).
    if (_activeRuns.add(identity)) setActivity(true);
  }

  @override
  void runCompleted(Object identity) {
    if (_activeRuns.remove(identity)) setActivity(_activeRuns.isNotEmpty);
  }
}
