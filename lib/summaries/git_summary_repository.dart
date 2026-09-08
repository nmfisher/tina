import 'dart:io';
import '../environment/environment_repository.dart';
import 'allocations_store.dart';
import 'sidecar_repo.dart';
import 'summary_repository.dart';

/// Git/filesystem adapter. Inspection does not initialize or commit the sidecar.
class GitSummaryRepository implements SummaryRepository {
  final SidecarSummaryRepo sidecar;
  final AllocationsStore? allocations;
  final EnvironmentRepository environment;
  final List<String>? partition;
  GitSummaryRepository({
    required this.sidecar,
    required this.environment,
    this.allocations,
    this.partition,
  });
  @override
  bool get proposalShown => sidecar.proposalShown;
  @override
  void markProposalShown() => sidecar.markProposalShown();
  @override
  SummarySnapshot inspect() {
    final manifest = sidecar.loadManifest();
    final parts = partition ?? partitionFor(sidecar, allocations);
    final stale = sidecar.staleDirs(parts, manifest);
    String? sha;
    try {
      sha = sidecar.headCommit();
    } on ProcessException {
      sha = null;
    }
    final env = environment.inspect();
    return SummarySnapshot(
      manifest: manifest,
      repartitioned: sidecar.staleDirs(parts, SummaryManifest.empty()),
      status: SummaryIndexStatus(
        totalDirs: parts.length,
        staleDirs: stale.toRegenerate,
        deletedDirs: stale.deleted,
        headSha: sha,
        firstRun: manifest.dirs.isEmpty,
        hasAllocations: allocations?.dirs.isNotEmpty ?? false,
        envFirstLoad: !env.recordPresent,
        envStaleReason: env.staleReason,
      ),
    );
  }

  @override
  void prepare() => sidecar.init();
  @override
  List<String> record(SummaryPlan plan) {
    final work = plan.work;
    final updated = sidecar.record(
      manifest: plan.manifest,
      regenerated: work.toRegenerate,
      deleted: work.deleted,
    );
    sidecar.saveManifest(updated);
    sidecar.commit(
      regenerated: work.toRegenerate,
      deleted: work.deleted,
      commitSha: sidecar.headCommit(),
    );
    return work.toRegenerate.where(sidecar.summaryWritten).toList();
  }
}
