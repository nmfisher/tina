import 'dart:async';
import 'dart:io';

import 'package:tina/composition/agent_composition.dart';
import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina_engine/tina_engine.dart';

import 'sidecar_repo.dart';

/// Drives the per-directory summary fleet: a headless orchestrator agent that
/// fans out one sub-agent per stale directory, each writing its summary to the
/// sidecar via [WriteSummaryTool]. After the run, the sidecar manifest is
/// updated and a commit records the change.
///
/// Reuses the live agent fleet (`buildAppComposition` + `buildAgent` + a real
/// [SubAgentScheduler] + [DelegateTool]) rather than a bespoke loop. The
/// orchestrator is the entry agent with a summarization-specific `system:`
/// prompt; each delegated sub-agent inherits that identity and runs read-only
/// (read/search/grep/glob + `write_summary`), so it can read the directory and
/// capture its summary but cannot touch source files.
class SummaryRunner {
  SummaryRunner({
    required this.config,
    required this.registry,
    this.environment,
    this.projectRoot,
    this.dryRun = false,
    this.repartition = false,
    this.dirs,
    this.spendLedger,
  });

  final Config config;
  final ProviderRegistry registry;
  final Environment? environment;

  /// The LIVE session's ledger, when this runner is driven in-process
  /// (`/index` inside a session): the fleet's ephemeral ledger is merged into
  /// it after the run, so the fleet's spend counts toward the session total.
  /// null headless (the fleet's ledger stays throwaway).
  final SpendLedger? spendLedger;

  /// The main repo root to summarize. Defaults to the process cwd at [run]
  /// time (matching `bin/tina.dart`'s convention). Overridable so tests can
  /// point at a temp repo without mutating the process-wide cwd (which would
  /// race with concurrent tests).
  final String? projectRoot;
  final bool dryRun;
  final bool repartition;

  /// Restrict regeneration to these directories (e.g. a freshly allocated
  /// region). null = everything stale.
  final List<String>? dirs;

  /// Run the summary fleet against [projectRoot]. Returns the stale set that
  /// was (or would be) regenerated.
  Future<StaleSet> run() async {
    // The sidecar repo root is `<projectRoot>/.tina`, so its `summaries/`
    // dir lands at `<projectRoot>/.tina/summaries` — the same path
    // `configureToolSandbox` sets as the `write_summary` tool's sidecarRoot.
    // Keeping the two in sync is what lets the summarizer children write into
    // the very repo this driver commits.
    final project = projectRoot ?? _projectRoot();
    final repo = SidecarSummaryRepo(
      root: Directory('$project/.tina'),
      projectRoot: Directory(project),
    );
    repo.init();
    var manifest = repo.loadManifest();
    if (repartition) {
      manifest = SummaryManifest.empty();
    }
    final partition = repo.defaultPartition();
    final stale = repo.staleDirs(partition, manifest);
    // A dirs filter restricts regeneration to the named dirs (allocations);
    // deletions are never filtered — a dir out of the partition is gone.
    final toRegenerate = dirs == null
        ? stale.toRegenerate
        : stale.toRegenerate.where(dirs!.contains).toList();
    final effective = StaleSet(
        toRegenerate: toRegenerate, deleted: stale.deleted);

    if (dryRun) {
      return effective;
    }
    if (effective.isEmpty && !repartition) {
      return effective;
    }

    // buildAppComposition (below) re-sets the shared registry's `decorator` to a
    // fresh ephemeral MeteringProvider/SpendLedger. When this runner is driven
    // in-process (e.g. /index inside a live session), that mutation would leak
    // to the caller's registry and silently break /spend metering on later
    // /spawn /model builds. Save/restore here — at the layer that owns the
    // mutation — so every caller is protected, and so the save/restore is
    // testable via the summary_runner harness without standing up the caller.
    final savedDecorator = registry.decorator;
    try {
      // Build the composition — this configures the shared tool singletons,
      // including _writeSummary.sidecarRoot (via configureToolSandbox, which uses
      // Directory.current.path). Re-configure with the runner's explicit
      // [projectRoot] so the write_summary tool targets this repo regardless of
      // the process cwd (configureToolSandbox is idempotent).
      final app = await buildAppComposition(
        config: config,
        registry: registry,
        environment: environment,
      );
      if (projectRoot != null) {
        configureToolSandbox(
          projectRoot: project,
          env: (environment ?? const PlatformEnvironment()).env,
        );
      }

      final host = HeadlessHost();
      // The top agent is the orchestrator with a summarization identity: it has
      // only `delegate` + channels (no file tools, structurally — see
      // buildAgent's withSubAgents path), which is exactly the shape we want.
      final agent = buildAgent(
        pipeline: app.pipeline,
        scheduler: app.scheduler,
        conversationId: app.initialConversationId,
        provider: app.provider,
        host: host,
        policy: app.policy,
        config: config,
        withSubAgents: true,
        system: _orchestratorPrompt(effective.toRegenerate),
      );

      final history = <Message>[];
      try {
        await agent.run(
          history: history,
          userInput: _userPrompt(effective.toRegenerate),
        );
      } finally {
        await host.dispose();
        await app.scheduler.dispose();
        app.provider.close();
      }

      // After the fleet ran, record the regenerated + deleted dirs and commit.
      final updated = repo.record(
        manifest: manifest,
        regenerated: effective.toRegenerate,
        deleted: effective.deleted,
      );
      repo.saveManifest(updated);
      final commitSha = repo.headCommit();
      repo.commit(
        regenerated: effective.toRegenerate,
        deleted: effective.deleted,
        commitSha: commitSha,
      );

      // An in-process /index counts toward the session's spend: fold the
      // fleet's ephemeral ledger into the live one (the fleet ran on its own
      // composition + throttle, so only tokens are merged).
      spendLedger?.merge(app.spendLedger);
    } finally {
      registry.decorator = savedDecorator;
    }

    return effective;
  }

  String _projectRoot() => Directory.current.path;

  String _userPrompt(List<String> staleDirs) {
    if (staleDirs.isEmpty) {
      return 'No directories are stale. Nothing to summarize.';
    }
    final lines = StringBuffer()
      ..writeln('Regenerate per-directory summaries for the following stale '
          'directories. For each, delegate a sub-agent with the task "read '
          '<dir> and write its summary with write_summary". Batch at most 8 '
          'per `delegate` call.\n');
    for (final dir in staleDirs) {
      lines.writeln('- $dir');
    }
    return lines.toString();
  }

  String _orchestratorPrompt(List<String> staleDirs) => '''
You are the summarization orchestrator for a code repository. Your sole job is to fan out sub-agents — one per stale directory — so each reads its directory and writes a prose summary into the sidecar store.

For each directory listed in the user message, delegate a sub-agent with the task: "Read <dir> and write a markdown summary of it by calling write_summary("<dir>", <content>). Do not include a tracking header — write_summary stamps it." The sub-agents run read-only (they get read, search, grep, glob, and write_summary). Batch at most 8 delegations per `delegate` call (the tool caps it); if there are more, make multiple calls. Do not summarize directories yourself — always delegate. Do not write plans or run review loops; this is a pure fan-out.

When every directory has been delegated, stop. Your final answer is a one-line confirmation of how many directories you summarized.''';
}
