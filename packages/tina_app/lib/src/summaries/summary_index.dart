import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/src/execution/project_execution.dart';
import 'package:tina_app/src/summaries/summary_repository.dart';
import 'package:tina_app/src/summaries/summary_models.dart';
export 'package:tina_app/src/summaries/summary_models.dart' show SummaryIndexStatus, SummaryIndexResult;

abstract interface class SummaryFleet {
  /// Owns execution resources until settled. Throws before recording on failure.
  Future<SpendLedger> run(SummaryPlan plan, RunInteraction interaction);
}

/// Status-only consumers need a repository, never execution configuration.
class SummaryInspection {
  final SummaryRepository repository;
  SummaryInspection({required this.repository});
  Future<SummaryIndexStatus> status() async => repository.inspect().status;
  bool get proposalShown => repository.proposalShown;
  void markProposalShown() => repository.markProposalShown();
}

/// Coordinates planning, execution and verified recording without filesystem IO.
class SummaryIndex extends SummaryInspection {
  final SummaryFleet fleet;
  final SpendLedger? spendLedger;
  SummaryIndex({
    required super.repository,
    required this.fleet,
    this.spendLedger,
  });

  Future<SummaryIndexResult> refresh({
    bool repartition = false,
    bool dryRun = false,
    List<String>? dirs,
    HostInterface? host,
    Future<void>? cancelSignal,
  }) async {
    final plan = planSummaries(
      repository.inspect(),
      repartition: repartition,
      dryRun: dryRun,
      dirs: dirs,
    );
    var landed = <String>[];
    if (plan.shouldExecute) {
      repository.prepare();
      final usage = await fleet.run(
        plan,
        RunInteraction(host: host, cancelSignal: cancelSignal),
      );
      landed = repository.record(plan);
      // Preserve accounting: summary spend merges only after recording/commit.
      spendLedger?.merge(usage);
    }
    return SummaryIndexResult(
      status: await status(),
      regenerated: landed.length,
      regeneratedDirs: landed,
      deletedDirs: plan.work.deleted,
      planned: plan.work,
    );
  }
}
