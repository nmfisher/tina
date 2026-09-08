import 'package:tina_engine/tina_engine.dart';
import '../conversation.dart';
import '../environment/environment_index.dart';
import '../summaries/summary_index.dart';
import 'background_job_supervisor.dart';

/// Binds A05 services to job ownership and completion notices, without input IO.
class ProjectBackgroundJobs {
  final BackgroundJobSupervisor supervisor;
  final SummaryIndex? Function() summaryIndex;
  final EnvironmentIndex? Function() environmentIndex;
  final Future<void> Function(Conversation) persistUsage;
  ProjectBackgroundJobs({
    required this.supervisor,
    required this.summaryIndex,
    required this.environmentIndex,
    required this.persistUsage,
  });
  bool get isIndexRunning => supervisor.running('index');
  bool get isEnvironmentRunning => supervisor.running('environment');
  Future<void> runEnvironment(Conversation conv) {
    if (conv.isClosed) return Future.value();
    if (isEnvironmentRunning) {
      conv.host.showMessage(
        'the environment agent is already running in the background\n',
        style: HostMessageStyle.warning,
      );
      return Future.value();
    }
    supervisor.start(
      'environment',
      conv.id,
      (job) => _doBackgroundEnvironment(conv, cancel: job),
    );
    return Future.value();
  }

  /// The background environment-agent task. Posts start/completion notices to
  /// [conv]'s host and clears the guard when done.
  Future<void> _doBackgroundEnvironment(
    Conversation conv, {
    required BackgroundJob cancel,
  }) async {
    final idx = environmentIndex();
    if (idx == null) {
      return;
    }
    try {
      final ok = await idx.refresh(
        host: conv.host,
        cancelSignal: cancel.cancelled,
      );
      if (cancel.cancellationRequested) {
        conv.host.showMessage(
          '[environment agent cancelled]\n',
          style: HostMessageStyle.warning,
        );
      } else if (ok) {
        conv.host.showMessage(
          'Environment record updated (.tina/ENVIRONMENT.md).\n',
          style: HostMessageStyle.success,
        );
      } else {
        conv.host.showMessage(
          'environment agent did not update .tina/ENVIRONMENT.md — the record '
          'stays stale\n',
          style: HostMessageStyle.warning,
        );
      }
    } catch (e) {
      conv.host.showMessage(
        'environment agent failed: $e\n',
        style: HostMessageStyle.error,
      );
    } finally {
      await persistUsage(conv);
    }
  }

  Future<void> runIndex(
    Conversation conv,
    List<String>? dirs, {
    bool repartition = false,
  }) {
    if (conv.isClosed) return Future.value();
    if (isIndexRunning) {
      conv.host.showMessage(
        '/index is already running in the background\n',
        style: HostMessageStyle.warning,
      );
      return Future.value();
    }
    supervisor.start(
      'index',
      conv.id,
      (job) =>
          _doBackgroundIndex(conv, dirs, repartition: repartition, cancel: job),
    );
    return Future.value();
  }

  /// The background fleet task. Posts start/completion notices to [conv]'s
  /// host, clears [_indexCancel] when done (when it's still ours — a newer
  /// run can't start while this one holds the guard, so it always is).
  Future<void> _doBackgroundIndex(
    Conversation conv,
    List<String>? dirs, {
    required bool repartition,
    required BackgroundJob cancel,
  }) async {
    final idx = summaryIndex();
    if (idx == null) {
      return;
    }
    final n = dirs?.length;
    conv.host.showMessage(
      'Indexing ${n == null ? 'all dirs' : '$n ${n == 1 ? 'dir' : 'dirs'}'} '
      'in the background (Esc-Esc to cancel)…\n',
    );
    try {
      final r = await idx.refresh(
        repartition: repartition,
        dirs: dirs,
        host: conv.host,
        cancelSignal: cancel.cancelled,
      );
      if (cancel.cancellationRequested) {
        conv.host.showMessage(
          '[index cancelled]\n',
          style: HostMessageStyle.warning,
        );
      } else {
        final sha = r.status.headSha;
        final at = sha == null
            ? ''
            : ' @ ${sha.length >= 7 ? sha.substring(0, 7) : sha}';
        conv.host.showMessage(
          'Indexed ${r.regenerated} '
          '${r.regenerated == 1 ? 'directory' : 'directories'}$at.\n',
          style: HostMessageStyle.success,
        );
      }
    } catch (e) {
      conv.host.showMessage(
        'index failed: $e\n',
        style: HostMessageStyle.error,
      );
    } finally {
      await persistUsage(conv);
    }
  }
}
