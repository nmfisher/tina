import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

import '../self_update/release_checker.dart';
import '../self_update/updater.dart';
import '../version.g.dart';
import '../summaries/summary_index.dart';
import '../pipeline/pipeline_commands.dart';
import '../tmux/tmux_support.dart';
import 'command_context.dart';
import 'session_export.dart';

import 'command_capabilities.dart';
part 'session_command_registry.dart';
part 'command_families.dart';

/// The slash-command handlers, lifted out of [SessionController] so they can be
/// read and tested in isolation. Operates purely through a [CommandContext] —
/// no input loop, no host of its own. [dispatch] is the entry point the
/// controller calls each input line; it echoes the command, runs any registered
/// hook, and switches on the command word exactly as the controller used to.
class SessionCommandHandlers {
  final DispatchCapabilities ctx;
  final UsageCommands usage;
  final UpdateCommands update;
  final FrontendCommands frontend;
  final SessionsCommands sessions;
  final HistoryCommands history;
  final PermissionsCommands permissions;
  final IndexCommands index;
  final WorkflowCapabilities workflow;

  /// Legacy adapter for existing integrations. Each family receives a narrow view.
  SessionCommandHandlers(
    CommandContext context, {
    ReleaseChecker? Function(Map<String, String> env)? releaseCheckerFactory,
  }) : this.withCapabilities(
         dispatch: context,
         usage: context,
         update: context,
         frontend: context,
         sessions: context,
         history: context,
         permissions: context,
         index: context,
         workflow: context,
         releaseCheckerFactory: releaseCheckerFactory,
       );

  SessionCommandHandlers.withCapabilities({
    required DispatchCapabilities dispatch,
    required UsageCapabilities usage,
    required UpdateCapabilities update,
    required FrontendCapabilities frontend,
    required SessionsCapabilities sessions,
    required HistoryCapabilities history,
    required PermissionsCapabilities permissions,
    required IndexCapabilities index,
    required this.workflow,
    ReleaseChecker? Function(Map<String, String> env)? releaseCheckerFactory,
  }) : ctx = dispatch,
       usage = UsageCommands(usage),
       update = UpdateCommands(
         update,
         releaseCheckerFactory: releaseCheckerFactory,
       ),
       frontend = FrontendCommands(frontend),
       sessions = SessionsCommands(sessions),
       history = HistoryCommands(history),
       permissions = PermissionsCommands(permissions),
       index = IndexCommands(index);

  /// Seam for tests: builds the [ReleaseChecker] `/update` uses. Production
  /// calls leave it null and a real checker (with [Platform.environment])
  /// is constructed per invocation and closed afterwards.

  /// Every recognized slash command, in display order — derived from the
  /// command registry ([registry], via [SessionCommandRegistry.allNames]),
  /// which remains the single source of truth for [dispatch] and the `/`
  /// command-completion palette ([CommandCompletionProvider]). Kept as a
  /// getter (not deleted) because existing tests and callers name it; the
  /// compiler-checked derivation cannot drift from the registry.
  static List<String> get allCommands => registry.allNames;

  /// The ordered command table every command surface dispatches, completes,
  /// and renders help from.
  static final SessionCommandRegistry registry = SessionCommandRegistry(
    _kSessionCommandEntries,
  );

  Future<CmdResult> dispatch(String trimmed) async {
    final word = trimmed.split(RegExp(r'\s+')).first;
    final entry = registry.lookup(word);
    if (entry == null) {
      if (word.startsWith('/')) {
        ctx.active.host.showMessage(
          '$word: unknown command\n',
          style: HostMessageStyle.error,
        );
        return const CmdHandled();
      }
      return const CmdNotCommand();
    }

    ctx.active.host.showMessage('$trimmed\n', style: HostMessageStyle.user);
    ctx.active.host.showSeparator();

    // Run any registered hook for this command before the default action. The
    // hook may prepare or clear state that the default handler then acts on.
    // Keyed by the typed word, so hooks fire for aliases too (`/quit` fires
    // the `/quit` hook, not the `/exit` one).
    final hook = ctx.commandHooks[word];
    if (hook != null) {
      await hook();
    }

    return entry.handler(this, trimmed);
  }

  void _printHelp() {
    // Rendered structurally from the command registry — same bytes as the
    // pre-registry literal (golden-tested in
    // test/session_commands/session_command_registry_test.dart).
    ctx.active.host.showMessage(registry.renderHelp());
  }
}

/// The first-run `/index` proposal prompt: the live main agent reviews the
/// repo structure and designs the region layout (which folders get index
/// agents), allocating freely — the user approves the layout when `/index`
/// runs again, and then the fleet summarizes exactly those regions.
const String _proposalPrompt = '''
No region index exists for this repository yet. Design one: review the folder structure with `repo_structure`, then decide which folders deserve a region agent — a persistent summary of what exists and is implemented there, served by a fast agent that answers questions about that folder.

Use your judgment: skip folders that are too small or trivial to matter; merge closely-related folders into one region; split large, dense folders if they cover several concerns. For every folder you choose, call `allocate_region` with the folder's path (optionally llm_provider + llm_model for a dedicated fast model).

When you are done, report the proposed layout — the folders you allocated and a one-line reason for each — and end your response with: run `/index` again to approve this layout and generate the summaries.''';

/// How [runIndexDance] launches the fleet. Null = run it inline via
/// [SummaryIndex.refresh] and await it (headless). Non-null = hand it off
/// (the TUI's background task), returning immediately — the task posts its
/// own start/completion notices, so the dance skips its own.
typedef IndexRefreshFn =
    Future<SummaryIndexResult?> Function({
      bool repartition,
      List<String>? dirs,
    });

/// The `/index` staleness dance, factored out of [SessionCommandHandlers] so the
/// headless runner (`bin/tina.dart --non-interactive -p /index`) can reuse it
/// without a [SessionController]: probe staleness (pure git, no LLM), then
/// branch — index all on a first run / when everything is stale; re-run only the
/// stale dirs when partly stale; report up-to-date and confirm (when [confirm]
/// is wired, i.e. the TUI) before a full re-run. The fleet runs via
/// [SummaryIndex.refresh] (inline, awaited) or is handed to [refreshFn] (the
/// TUI's background task); notices go to [host].
Future<CmdResult> runIndexDance({
  required HostInterface host,
  required SummaryIndex summaryIndex,
  Future<bool> Function(String prompt)? confirm,
  IndexRefreshFn? refreshFn,
  Future<void> Function()? runEnvironment,
}) async {
  // Run the fleet and report, or hand it off. [startMsg] is posted only in
  // inline mode (the background task announces itself); [verb] labels the
  // inline completion report.
  Future<void> refreshAndReport({
    required String startMsg,
    required String verb,
    bool repartition = false,
    List<String>? dirs,
  }) async {
    if (refreshFn != null) {
      await refreshFn(repartition: repartition, dirs: dirs);
      return;
    }
    if (startMsg.isNotEmpty) host.showMessage(startMsg);
    final r = await summaryIndex.refresh(repartition: repartition, dirs: dirs);
    _postIndexRefresh(host, r, verb: verb);
  }

  final status = await summaryIndex.status();

  // The environment region: the dance flags, the environment agent acts
  // (docs/proposals/environment_agent.md, "Region integration"). Independent
  // of the dir branches below, so it runs whichever way they go. The TUI hands
  // it to its background task; headless only reports (an unattended run must
  // not install dependencies or touch git config).
  if (status.envStale) {
    if (runEnvironment != null) {
      host.showMessage(
        status.envFirstLoad
            ? 'No environment record yet — running the environment agent in the '
                  'background (Esc-Esc to cancel)…\n'
            : 'Environment record is stale (${status.envStaleReason}) — running '
                  'the environment agent in the background…\n',
      );
      await runEnvironment();
    } else {
      host.showMessage(
        'Environment record is ${status.envFirstLoad ? 'missing' : 'stale'}'
        '${status.envStaleReason == null ? '' : ' (${status.envStaleReason})'}'
        ' — refresh it from an interactive session.\n',
      );
    }
  }

  if (status.totalDirs == 0) {
    host.showMessage('No directories to index.\n');
    return const CmdHandled();
  }

  // First run in the TUI: the MAIN AGENT designs the region layout before any
  // fleet run. No allocations yet → hand it a proposal turn (CmdRun runs the
  // prompt through the normal turn path); allocations exist but nothing is
  // summarized → the user approves the proposed layout, then the fleet runs.
  // Headless passes confirm == null and keeps the deterministic default
  // partition below.
  if (status.firstRun && confirm != null) {
    if (!status.hasAllocations) {
      // Escape hatch: a proposal turn already ran and still no allocations
      // (the agent allocated nothing, or every region was since deleted).
      // Offering another paid proposal turn would loop forever — fall back to
      // confirming the default partition instead.
      if (summaryIndex.proposalShown) {
        final fallback = await confirm(
          'The proposal turn ran but allocated no regions. '
          'Index the default partition instead? [y/N] ',
        );
        if (!fallback) return const CmdHandled();
        await refreshAndReport(
          startMsg:
              'Indexing ${status.totalDirs} '
              '${status.totalDirs == 1 ? 'directory' : 'directories'}…\n',
          verb: 'Indexed',
          dirs: status.staleDirs,
        );
        return const CmdHandled();
      }
      host.showMessage(
        'No region index yet — the main agent will design the layout.\n',
      );
      summaryIndex.markProposalShown();
      return CmdRun(_proposalPrompt);
    }
    final ok = await confirm(
      'Summarize the ${status.totalDirs} proposed '
      'regions? [y/N] ',
    );
    if (!ok) return const CmdHandled();
    await refreshAndReport(
      startMsg:
          'Indexing ${status.totalDirs} '
          '${status.totalDirs == 1 ? 'region' : 'regions'}…\n',
      verb: 'Indexed',
      dirs: status.staleDirs,
    );
    return const CmdHandled();
  }

  // First run (empty manifest) or every dir changed since the last index.
  if (status.firstRun || status.allStale) {
    await refreshAndReport(
      startMsg:
          'Indexing ${status.totalDirs} '
          '${status.totalDirs == 1 ? 'directory' : 'directories'}…\n',
      verb: 'Indexed',
      dirs: status.staleDirs,
    );
    return const CmdHandled();
  }

  // Nothing stale → up to date. Confirm before re-running everything.
  if (status.staleCount == 0) {
    host.showMessage(
      'Index is up to date (${status.totalDirs} dirs'
      '${status.headSha != null ? ' @ ${_shortSha(status.headSha!)}' : ''}).\n',
    );
    if (confirm == null) {
      // Headless: no interactive input, so a re-run can't be confirmed.
      return const CmdHandled();
    }
    final ok = await confirm(
      'Re-run all ${status.totalDirs} summaries anyway? [y/N] ',
    );
    if (!ok) return const CmdHandled();
    await refreshAndReport(
      startMsg: 'Re-indexing ${status.totalDirs} dirs…\n',
      verb: 'Re-indexed',
      repartition: true,
    );
    return const CmdHandled();
  }

  // Partly stale: re-run just the stale dirs. The stale-dirs report posts in
  // both modes (it explains WHAT the background run is doing).
  host.showMessage(
    '${status.staleCount}/${status.totalDirs} dirs stale: '
    '${status.staleDirs.join(', ')}. Refreshing…\n',
  );
  await refreshAndReport(
    startMsg: '',
    verb: 'Refreshed',
    dirs: status.staleDirs,
  );
  return const CmdHandled();
}

void _postIndexRefresh(
  HostInterface host,
  SummaryIndexResult r, {
  required String verb,
}) {
  final n = r.regenerated;
  final parts = <String>['$verb $n ${n == 1 ? 'directory' : 'directories'}'];
  if (r.deletedDirs.isNotEmpty) {
    parts.add('removed ${r.deletedDirs.length}');
  }
  if (r.status.headSha != null) {
    parts.add('@ ${_shortSha(r.status.headSha!)}');
  }
  host.showMessage('${parts.join(', ')}.\n', style: HostMessageStyle.success);
}

String _shortSha(String sha) => sha.length >= 7 ? sha.substring(0, 7) : sha;
