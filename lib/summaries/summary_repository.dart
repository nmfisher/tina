import 'summary_models.dart';

class SummarySnapshot {
  final SummaryManifest manifest;
  final SummaryIndexStatus status;

  /// Staleness against an empty manifest, captured with the normal inspection.
  final StaleSet repartitioned;
  const SummarySnapshot({
    required this.manifest,
    required this.status,
    required this.repartitioned,
  });
}

class SummaryPlan {
  final SummaryManifest manifest;
  final StaleSet work;
  final bool repartition;
  final bool dryRun;
  const SummaryPlan({
    required this.manifest,
    required this.work,
    required this.repartition,
    required this.dryRun,
  });
  bool get shouldExecute => !dryRun && (!work.isEmpty || repartition);
}

/// Pure selection over a captured inspection; deletion is never dir-filtered.
SummaryPlan planSummaries(
  SummarySnapshot snapshot, {
  bool repartition = false,
  bool dryRun = false,
  List<String>? dirs,
}) {
  final stale = repartition
      ? snapshot.repartitioned
      : StaleSet(
          toRegenerate: snapshot.status.staleDirs,
          deleted: snapshot.status.deletedDirs,
        );
  return SummaryPlan(
    manifest: repartition ? SummaryManifest.empty() : snapshot.manifest,
    work: StaleSet(
      toRegenerate: List.unmodifiable(
        dirs == null
            ? stale.toRegenerate
            : stale.toRegenerate.where(dirs.contains),
      ),
      deleted: List.unmodifiable(stale.deleted),
    ),
    repartition: repartition,
    dryRun: dryRun,
  );
}

abstract interface class SummaryRepository {
  SummarySnapshot inspect();

  /// Initialize output storage only when executing real work.
  void prepare();
  bool get proposalShown;
  void markProposalShown();

  /// Verify landed files, record at the current HEAD, and commit. Returns the
  /// existing file-presence count (including a pre-existing summary file).
  List<String> record(SummaryPlan plan);
}
