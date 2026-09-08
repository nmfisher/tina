import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/src/execution/project_execution.dart';
import 'package:tina_app/src/environment/environment_repository.dart';

class EnvironmentExecutionResult {
  final bool completed;
  final SpendLedger usage;
  const EnvironmentExecutionResult(this.completed, this.usage);
}

abstract interface class EnvironmentAgentRunner {
  Future<EnvironmentExecutionResult> execute(
    EnvironmentSnapshot before,
    RunInteraction interaction, {
    String? modelRef,
  });
}

class EnvironmentInspection {
  final EnvironmentRepository repository;
  EnvironmentInspection({required this.repository});
  EnvironmentStatus status() {
    final snapshot = repository.inspect();
    return EnvironmentStatus(
      recordPresent: snapshot.recordPresent,
      staleReason: snapshot.staleReason,
    );
  }
}

class EnvironmentIndex extends EnvironmentInspection {
  final EnvironmentAgentRunner runner;
  final SpendLedger? spendLedger;
  EnvironmentIndex({
    required super.repository,
    required this.runner,
    this.spendLedger,
  });
  Future<bool> refresh({
    HostInterface? host,
    Future<void>? cancelSignal,
    String? modelRef,
    PermissionAsker? asker,
    AgentSink Function(String dir)? scoutSinkFactory,
  }) async {
    final before = repository.inspect(captureRecord: true);
    final result = await runner.execute(
      before,
      RunInteraction(
        host: host,
        cancelSignal: cancelSignal,
        asker: asker,
        scoutSinkFactory: scoutSinkFactory,
      ),
      modelRef: modelRef,
    );
    // Existing environment accounting includes cancelled/no-write runs, but
    // excludes executions that throw before returning a settled result.
    spendLedger?.merge(result.usage);
    if (!result.completed || !repository.advanced(before)) return false;
    repository.record();
    return true;
  }
}

/// The pure-read staleness answer for the environment region.
class EnvironmentStatus {
  /// Whether `.tina/ENVIRONMENT.md` exists — false means first load: the environment
  /// agent should populate it from measurements.
  final bool recordPresent;

  /// Why the region is stale, or null when current. From the machine-owned
  /// tracking entry, never from the record's prose.
  final String? staleReason;

  const EnvironmentStatus({required this.recordPresent, this.staleReason});

  bool get stale => staleReason != null;
}
