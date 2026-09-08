import '../agent/run_lifecycle.dart';

/// Activity is derived from all active identities, not the last run to finish.
mixin HostLifecycleAdapter implements RunLifecycleSink {
  final Set<Object> _activeRuns = {};
  bool get hasActiveRuns => _activeRuns.isNotEmpty;
  void setActivity(bool active);
  @override
  void runStarted(Object identity) {
    _activeRuns.add(identity);
    setActivity(true);
  }

  @override
  void runCompleted(Object identity) {
    if (_activeRuns.remove(identity)) setActivity(_activeRuns.isNotEmpty);
  }
}
