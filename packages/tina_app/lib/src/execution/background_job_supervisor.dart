import 'dart:async';

class BackgroundJob {
  final int id;
  final String kind;
  final String conversationId;
  final _cancel = Completer<void>();
  final _done = Completer<void>();
  Object? error;
  BackgroundJob(this.id, this.kind, this.conversationId);
  Future<void> get cancelled => _cancel.future;
  Future<void> get done => _done.future;
  bool get cancellationRequested => _cancel.isCompleted;
  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }
}

/// One active job per kind across the application, matching existing guards.
/// Completion always settles; failures remain observable on the handle.
class BackgroundJobSupervisor {
  final _jobs = <String, BackgroundJob>{};
  bool _closing = false;
  int _next = 0;
  Future<void>? _shutdown;
  bool running(String kind) => _jobs.containsKey(kind);
  BackgroundJob? start(
    String kind,
    String conversationId,
    Future<void> Function(BackgroundJob job) work,
  ) {
    if (_closing || _jobs.containsKey(kind)) return null;
    final job = BackgroundJob(++_next, kind, conversationId);
    _jobs[kind] = job;
    unawaited(() async {
      try {
        await work(job);
      } catch (e) {
        job.error = e;
      } finally {
        _jobs.remove(kind);
        job._done.complete();
      }
    }());
    return job;
  }

  void cancelAll() {
    for (final job in _jobs.values) {
      job.cancel();
    }
  }

  Future<void> shutdown() => _shutdown ??= _stop();
  Future<void> _stop() async {
    _closing = true;
    final jobs = _jobs.values.toList();
    cancelAll();
    await Future.wait(jobs.map((j) => j.done));
  }
}
