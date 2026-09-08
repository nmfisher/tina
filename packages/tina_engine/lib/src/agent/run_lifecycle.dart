/// Minimal run lifecycle: identities distinguish nested/concurrent work.
abstract interface class RunLifecycleSink {
  void runStarted(Object identity);
  void runCompleted(Object identity);
}

/// Exactly one completion per started scope. Cosmetic observers cannot affect
/// execution or cleanup. Hosts may also use this for work surrounding Agent.run.
class RunActivity {
  final Object identity = Object();
  final RunLifecycleSink? _sink;
  bool _completed = false;
  RunActivity(Object sink) : _sink = sink is RunLifecycleSink ? sink : null {
    try {
      _sink?.runStarted(identity);
    } catch (_) {}
  }
  void complete() {
    if (_completed) return;
    _completed = true;
    try {
      _sink?.runCompleted(identity);
    } catch (_) {}
  }
}
