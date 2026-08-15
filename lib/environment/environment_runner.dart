import 'dart:async';
import 'dart:io';

import 'package:tina/composition/agent_composition.dart';
import 'package:tina/composition/app_composition.dart';
import 'package:tina/config.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina_engine/tina_engine.dart';

import 'environment_record.dart';
import 'environment_store.dart';

/// The background environment agent: one doing worker on the ephemeral
/// composition pattern (docs/proposals/environment_agent.md, "Agent
/// lifecycle") — build its own composition, run one agent, record, dispose.
/// Modeled on [SummaryRunner]: same decorator save/restore, same
/// build-then-dispose ownership, same in-process spend merge.
///
/// The agent measures the environment (toolchain, manifests, build/test
/// commands, auth), RUNS the setup, and writes `ENVIRONMENT.md` through the
/// ordinary sandboxed write/edit tools — under the real permission policy with
/// the host's asker, so every write and shell command prompts unless the user
/// allowed it (`--yolo` / `--allow bash:…`).
///
/// After the run, Dart code here — never the agent — records the tracking
/// entry, the machine-owned stale/fresh verdict under `.tina/environment/`.
class EnvironmentRunner {
  EnvironmentRunner({
    required this.config,
    required this.registry,
    this.environment,
    this.projectRoot,
    this.host,
    this.cancelSignal,
    this.spendLedger,
  });

  final Config config;
  final ProviderRegistry registry;
  final Environment? environment;

  /// The repo whose environment is measured. Defaults to the process cwd at
  /// [run] time (bin/tina.dart's convention); overridable so tests point at a
  /// temp repo without mutating the process-wide cwd.
  final String? projectRoot;

  /// Where the agent's prose + notices go. Defaults to a [HeadlessHost]; an
  /// in-session run passes the conversation's host so output streams into the
  /// chat panel instead of raw stdout over the TUI.
  final HostInterface? host;

  /// Completes to cancel the run mid-flight (Esc-Esc in the TUI).
  final Future<void>? cancelSignal;

  /// The LIVE session's ledger when driven in-process: the run's ephemeral
  /// ledger is merged into it after, so the spend counts toward the session
  /// total. Null headless (throwaway ledger).
  final SpendLedger? spendLedger;

  /// Run the environment agent. Returns true when the agent completed and the
  /// tracking entry was recorded; false when it was cancelled or produced no
  /// final answer — in which case nothing is recorded and the region stays
  /// stale, so it resurfaces on the next dance.
  Future<bool> run() async {
    final project = projectRoot ?? Directory.current.path;
    final firstLoad = !EnvironmentRecord.exists(project);
    final store = EnvironmentTrackingStore(projectRoot: project);

    // buildAppComposition re-sets the shared registry's decorator to a fresh
    // ephemeral MeteringProvider/SpendLedger. Save/restore here — at the layer
    // that owns the mutation — so the caller's registry is untouched (the
    // SummaryRunner rule).
    final savedDecorator = registry.decorator;
    try {
      final app = await buildAppComposition(
        config: config,
        registry: registry,
        environment: environment,
      );
      // Re-configure the shared tool singletons against the explicit
      // [projectRoot] so the agent's write/edit land in this repo regardless
      // of the process cwd (idempotent).
      if (projectRoot != null) {
        configureToolSandbox(
          projectRoot: project,
          env: (environment ?? const PlatformEnvironment()).env,
        );
      }

      final host = this.host ?? HeadlessHost();
      final ownedHost = this.host == null; // we created it; we dispose it.
      final provider = app.buildStartupProvider();
      final agent = buildAgent(
        pipeline: app.pipeline,
        scheduler: app.scheduler,
        conversationId: app.initialConversationId,
        provider: provider,
        host: host,
        policy: app.policy,
        config: config,
        withSubAgents: true,
        system: _identity,
      );

      final history = <Message>[];
      try {
        await agent.run(
          history: history,
          userInput: _taskPrompt(project, firstLoad, store.staleReason()),
          cancelSignal: cancelSignal,
        );
      } finally {
        if (ownedHost) await host.dispose();
        await app.scheduler.dispose();
        provider.close();
      }

      spendLedger?.merge(app.spendLedger);

      // Record only on a real finish: an aborted, cancelled, or
      // step-exhausted run leaves no final answer, and pinning the region
      // fresh at the current inputs would deadlock it until the code changed
      // (the unwritten-summary rule).
      if (agent.abortedReason != null || !_finished(history)) {
        return false;
      }
      store.record();
      return true;
    } finally {
      registry.decorator = savedDecorator;
    }
  }

  /// A finished run ends on an assistant text turn (the agent loop returns the
  /// instant a turn carries no tool calls). Every other terminal shape — out
  /// of steps, cancelled, a stream that ended on a tool call — is not a finish.
  bool _finished(List<Message> history) {
    if (history.isEmpty) return false;
    final last = history.last;
    if (last.role != Role.assistant) return false;
    return last.content.any((b) => b is TextBlock && b.text.trim().isNotEmpty);
  }

  static const _identity = '''
You are the environment agent for this repository. Your job is to establish and maintain the environment every agent here needs: dependencies installed, toolchain present, build and test commands known and working, git identity and GitHub auth configured. You are a doing worker — you run commands, you do not just describe them.

The repo's environment record is ENVIRONMENT.md at the repo root. It has two kinds of content: intent sections (Toolchain, Setup, Build, Test, Auth — the commands that should be run) and observed sections (the test baseline, "verified at" stamps — what the last run measured). The user may edit anything; treat the intent sections as authoritative and rewrite only the observed sections from your own fresh measurements.

Rules:
- Run the setup: dependency install, build, test. Use bash for commands and write/edit for the record.
- Measure before you claim: run the test suite and record what actually happened (counts, failures). Never invent a baseline.
- Auth entries are references only — never write tokens, passwords, or key material into the record. You may check auth (gh auth status, git config) and load keys (ssh-add); if something needs a typed secret, record "needs user action" instead.
- If a dependency step, command, or tool is missing, add or fix it in the intent sections and note what you changed.
- Delegate read-only exploration (reading manifests, checking the toolchain) to sub-agents when useful; keep the mutating actions to yourself.

Finish with a short report: what you ran, what passed, what failed, what needs user action.''';

  String _taskPrompt(String project, bool firstLoad, String? staleReason) {
    if (firstLoad) {
      return 'No ENVIRONMENT.md exists at $project yet. Populate it from '
          'measurements: inspect the dependency manifests and toolchain, run '
          'the setup, build, and tests, check git identity / SSH key / GitHub '
          'auth, then write ENVIRONMENT.md with the intent sections (Setup, '
          'Build, Test, Auth references) and the observed sections (Toolchain '
          'observed, Test baseline with real counts, verified-at stamp with '
          'the current commit).';
    }
    return 'The environment record is stale${staleReason == null ? '' : ': $staleReason'}. '
        'Re-verify: re-run the setup, build, and tests, check auth, and update '
        'ENVIRONMENT.md — the intent sections only where reality disagrees, '
        'and the observed sections (baseline, verified-at stamp) from fresh '
        'measurements.';
  }
}
