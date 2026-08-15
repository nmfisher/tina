import 'dart:io';

import 'package:meta/meta.dart';
import 'package:tina/config.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina_engine/tina_engine.dart';

import '../environment/environment_record.dart';
import '../environment/environment_store.dart';
import 'allocations_store.dart';
import 'sidecar_repo.dart';
import 'summary_runner.dart';

/// The in-app seam for the per-directory summary sidecar: a thin façade over
/// [SidecarSummaryRepo] (staleness, pure git) and [SummaryRunner] (the LLM
/// fleet). The `/index` session command closes over one of these via the
/// [CommandContext] callbacks to run the staleness dance — decide before
/// spending tokens, then regenerate only what's stale.
///
/// [status] is a pure-git probe (no LLM, no [Config]/[ProviderRegistry]
/// needed): it answers "how many dirs, which are stale, is this a first run".
/// [refresh] runs the fleet and so requires [config] + [registry] (it asserts
/// they're set); [environment] is passed through to the runner's composition so
/// the `write_summary` tool's sidecar root resolves against [projectRoot].
class SummaryIndex {
  SummaryIndex({
    required this.projectRoot,
    this.config,
    this.registry,
    this.environment,
    this.allocations,
    this.spendLedger,
  });

  /// The main repo root being summarized. The sidecar lives at
  /// `<projectRoot>/.tina/summaries`.
  final String projectRoot;

  /// Live-session composition parts; only required for [refresh]. Nullable so
  /// [status] (the staleness probe) can run without a composition — e.g. in a
  /// unit test, or before the session is fully wired.
  final Config? config;
  final ProviderRegistry? registry;
  final Environment? environment;

  /// User-allocated regions (main-agent-chosen directories beyond the default
  /// partition). null = the default partition only (headless `/index`).
  final AllocationsStore? allocations;

  /// The LIVE session's ledger, when wired by the coordinator: the fleet's
  /// usage is merged into it after an in-process refresh, so `/index` counts
  /// toward the session total. null headless (throwaway fleet ledger).
  final SpendLedger? spendLedger;

  /// The partition: the allocated regions when any exist (the main agent's
  /// proposed layout IS the index), else the default top-level dirs (the
  /// headless fallback, where no main agent proposes).
  List<String> partition(SidecarSummaryRepo repo) =>
      partitionFor(repo, allocations);

  SidecarSummaryRepo _repo() => SidecarSummaryRepo(
        root: Directory('$projectRoot/.tina'),
        projectRoot: Directory(projectRoot),
      );

  /// The underlying sidecar repo, for tests that seed a manifest before probing
  /// [status]. Not for production callers — [status]/[refresh] are the API.
  @visibleForTesting
  SidecarSummaryRepo repoForTest() => _repo();

  /// Whether the first-run layout proposal has already been shown (the
  /// `/index` escape hatch — see [SidecarSummaryRepo.proposalShown]).
  bool get proposalShown => _repo().proposalShown;

  /// Record that the proposal turn ran (see [proposalShown]).
  void markProposalShown() => _repo().markProposalShown();

  /// Pure-git staleness probe: the partition size, the stale dirs, the deleted
  /// dirs, the current HEAD sha, and whether the sidecar has ever been indexed
  /// (`firstRun`). No LLM, no side effects (does not `git init` the sidecar —
  /// [SummaryRunner.run] does that when it commits).
  Future<SummaryIndexStatus> status() async {
    final repo = _repo();
    final manifest = repo.loadManifest();
    final parts = partition(repo);
    final stale = repo.staleDirs(parts, manifest);
    String? sha;
    try {
      sha = repo.headCommit();
    } on ProcessException {
      sha = null; // no commits in the main repo yet — nothing to summarize.
    }
    return SummaryIndexStatus(
      totalDirs: parts.length,
      staleDirs: stale.toRegenerate,
      deletedDirs: stale.deleted,
      headSha: sha,
      firstRun: manifest.dirs.isEmpty,
      hasAllocations: (allocations?.dirs.isNotEmpty ?? false),
      envFirstLoad: !EnvironmentRecord.exists(projectRoot),
      envStaleReason: EnvironmentTrackingStore(projectRoot: projectRoot)
          .staleReason(),
    );
  }

  /// Run the summary fleet against [projectRoot]: one `summarizer` per stale
  /// directory (or all of them when [repartition] clears the manifest), then
  /// record + commit. [dirs] restricts regeneration to those directories (e.g.
  /// a freshly allocated region). [host] routes the fleet's output (defaults
  /// to a HeadlessHost — pass the conversation host in-session so the fleet
  /// streams into the chat panel, not raw stdout over the TUI); [cancelSignal]
  /// cancels the fleet mid-run. Returns what was regenerated plus a fresh
  /// post-run [SummaryIndexStatus]. Requires [config] + [registry] (asserted).
  Future<SummaryIndexResult> refresh({
    bool repartition = false,
    List<String>? dirs,
    HostInterface? host,
    Future<void>? cancelSignal,
  }) async {
    final cfg = config;
    final reg = registry;
    if (cfg == null || reg == null) {
      throw StateError(
        'SummaryIndex.refresh requires a Config + ProviderRegistry; '
        'the session command must wire them (status() does not).',
      );
    }
    final runner = SummaryRunner(
      config: cfg,
      registry: reg,
      environment: environment,
      projectRoot: projectRoot,
      dryRun: false,
      repartition: repartition,
      dirs: dirs,
      spendLedger: spendLedger,
      partition: partitionFor(_repo(), allocations),
      host: host,
      cancelSignal: cancelSignal,
    );
    // SummaryRunner.run() owns the registry.decorator save/restore (it calls
    // buildAppComposition, which re-sets the shared decorator). The live
    // session's spend funnel is therefore preserved across an in-process
    // /index run — see SummaryRunner.run.
    final stale = await runner.run();
    // Report what actually landed, not what was planned: a summarizer that
    // failed or skipped its write_summary call leaves no file, and record()
    // leaves the dir unrecorded (still stale). The counts the user sees must
    // match the summaries on disk.
    final repo = _repo();
    final landed =
        stale.toRegenerate.where(repo.summaryWritten).toList();
    return SummaryIndexResult(
      status: await status(),
      regenerated: landed.length,
      regeneratedDirs: landed,
      deletedDirs: stale.deleted,
    );
  }
}

/// A pure-git snapshot of the sidecar's staleness — the answer to "should
/// `/index` do anything, and what?". Carries everything the command handler
/// needs to branch + message without an LLM call.
class SummaryIndexStatus {
  final int totalDirs;
  final List<String> staleDirs;
  final List<String> deletedDirs;
  final String? headSha;
  final bool firstRun;

  /// Whether the main agent has allocated regions (the proposed layout exists
  /// but nothing is summarized yet on a first run).
  final bool hasAllocations;

  /// Whether `ENVIRONMENT.md` is absent — the environment agent's first-load
  /// signal. Pure file read, like the rest of this probe.
  final bool envFirstLoad;

  /// Why the environment region is stale, or null when current. From the
  /// machine-owned tracking entry under `.tina/environment/`, never from the
  /// record's prose.
  final String? envStaleReason;

  const SummaryIndexStatus({
    required this.totalDirs,
    required this.staleDirs,
    required this.deletedDirs,
    required this.headSha,
    required this.firstRun,
    this.hasAllocations = false,
    this.envFirstLoad = false,
    this.envStaleReason,
  });

  /// The environment region is stale (first load counts — nothing measured).
  bool get envStale => envFirstLoad || envStaleReason != null;

  int get staleCount => staleDirs.length;

  /// Every directory is stale — either a first run (empty manifest) or every
  /// tracked dir changed since the last index. The command handler treats this
  /// as "index all".
  bool get allStale => staleCount == totalDirs && totalDirs > 0;
}

/// The outcome of a [SummaryIndex.refresh] run: what was regenerated/deleted
/// plus the post-run status (which is up-to-date, modulo anything that changed
/// mid-run).
class SummaryIndexResult {
  final SummaryIndexStatus status;
  final int regenerated;
  final List<String> regeneratedDirs;
  final List<String> deletedDirs;

  const SummaryIndexResult({
    required this.status,
    required this.regenerated,
    required this.regeneratedDirs,
    required this.deletedDirs,
  });
}
