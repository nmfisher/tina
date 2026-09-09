import 'package:tina_engine/tina_engine.dart';

/// An owned execution scope without sessions, persistence or frontend state.
abstract interface class ProjectExecution {
  LlmProviderFactory get providers;
  PermissionPolicy get policy;
  AgentPipeline get pipeline;
  SubAgentScheduler get scheduler;
  SpendLedger get spendLedger;
  LlmProvider buildStartupProvider();
  Future<void> dispose();
}

typedef ProjectExecutionFactory = Future<ProjectExecution> Function();

/// Output, permission and cancellation adapters are borrowed for the run.
class RunInteraction {
  final HostInterface? host;
  final Future<void>? cancelSignal;
  final PermissionAsker? asker;

  /// The `"provider/model"` ref the run's agents should use, when the caller
  /// has a proven one (e.g. the active conversation's model). Null → the
  /// composition builds from the config defaults as before. A stale config
  /// default that the provider cannot serve must never doom a background
  /// run when a working ref is one field away.
  final String? modelRef;
  const RunInteraction({
    this.host,
    this.cancelSignal,
    this.asker,
    this.modelRef,
  });
}
