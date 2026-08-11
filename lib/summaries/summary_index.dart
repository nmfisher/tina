import 'dart:io';

import 'package:meta/meta.dart';
import 'package:tina/config.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina_engine/tina_engine.dart';

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
    );
  }

  /// Run the summary fleet against [projectRoot]: one `summarizer` per stale
  /// directory (or all of them when [repartition] clears the manifest), then
  /// record + commit. [dirs] restricts regeneration to those directories (e.g.
  /// a freshly allocated region). Returns what was regenerated plus a fresh
  /// post-run [SummaryIndexStatus]. Requires [config] + [registry] (asserted).
  Future<SummaryIndexResult> refresh({
    bool repartition = false,
    List<String>? dirs,
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
    );
    // SummaryRunner.run() owns the registry.decorator save/restore (it calls
    // buildAppComposition, which re-sets the shared decorator). The live
    // session's spend funnel is therefore preserved across an in-process
    // /index run — see SummaryRunner.run.
    final stale = await runner.run();
    return SummaryIndexResult(
      status: await status(),
      regenerated: stale.toRegenerate.length,
      regeneratedDirs: stale.toRegenerate,
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

  const SummaryIndexStatus({
    required this.totalDirs,
    required this.staleDirs,
    required this.deletedDirs,
    required this.headSha,
    required this.firstRun,
    this.hasAllocations = false,
  });

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
