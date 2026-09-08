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
/// Scout sinks remain owned by their factory's frontend, including on retry.
class RunInteraction {
  final HostInterface? host;
  final Future<void>? cancelSignal;
  final PermissionAsker? asker;
  final AgentSink Function(String dir)? scoutSinkFactory;
  const RunInteraction({
    this.host,
    this.cancelSignal,
    this.asker,
    this.scoutSinkFactory,
  });
}
