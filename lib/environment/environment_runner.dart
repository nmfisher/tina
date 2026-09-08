import 'dart:async';
import 'package:tina/composition/agent_composition.dart';
import 'package:tina/composition/runtime_resources.dart';
import 'package:tina/config/runtime_config.dart';
import 'package:tina_engine/tina_engine.dart';
import '../application/project_execution.dart';
import 'environment_repository.dart';
import 'environment_index.dart';

/// The shipped default model for the environment agent
/// (`[environment] model` in ~/.tina/config overrides it): Google's Diffusion
/// Gemma on NVIDIA NIM. The environment agent is a dedicated one-off worker,
/// so it gets its own model pick rather than inheriting the session's startup
/// model — which may be a weak-tool-calling model that struggles with the
/// env agent's large real payload (see the muse-glimmer tool-call mangling).
const kDefaultEnvironmentModelRef = 'nim/google/diffusiongemma-26b-a4b-it';

/// Executes environment/scout work using an injected project execution scope.
/// Scout sinks are borrowed; the frontend owns their panels and disposal.
class EnvironmentRunner implements EnvironmentAgentRunner {
  final RuntimeConfig config;
  final ProjectExecutionFactory executionFactory;
  final String projectRoot;
  final List<String> Function() surveyFolders;
  EnvironmentRunner({
    required this.config,
    required this.executionFactory,
    required this.projectRoot,
    required this.surveyFolders,
  });
  @override
  Future<EnvironmentExecutionResult> execute(
    EnvironmentSnapshot before,
    RunInteraction interaction, {
    String? modelRef,
  }) async {
    final project = projectRoot;
    final firstLoad = !before.recordPresent;
    final app = await executionFactory();
    final resources = RuntimeResources()..own(app.dispose);
    return resources.run(() async {
      final host = interaction.host ?? HeadlessHost();
      if (interaction.host == null) resources.own(host.dispose);
      // The environment agent runs on its OWN model — not the session's
      // startup model: a dedicated one-off worker deserves a dedicated pick
      // (and the startup model may be a weak-tool-calling one). Explicit
      // modelRef (the first-load picker's fresh choice) > the persisted
      // `[environment] model` > the shipped default. An unresolvable ref (a
      // registry without that provider — e.g. a stubbed test registry, or the
      // user's configured model was retired) falls back to the startup
      // provider rather than failing the run outright.
      final envRef =
          modelRef ?? config.environmentModel ?? kDefaultEnvironmentModelRef;
      LlmProvider provider;
      var agentModelRef = envRef;
      try {
        provider = app.providers.build(
          envRef,
          maxTokens: config.maxTokens,
          streamIdleTimeout: config.streamIdleTimeout,
          requestTimeout: config.requestTimeout,
        );
      } on ProviderRegistryException {
        agentModelRef = '${config.provider}/${config.model}';
        provider = app.buildStartupProvider();
      }
      resources.own(provider.close);
      resources.own(app.scheduler.dispose);
      final agent = buildAgent(
        pipeline: app.pipeline,
        scheduler: app.scheduler,
        conversationId: 'environment',
        provider: provider,
        host: host,
        policy: app.policy,
        config: config,
        withSubAgents: true,
        asker: interaction.asker,
        system: _identity,
      );

      final history = <Message>[];
      // The ceremony runs outside any session turn loop, so drive the host's
      // activity signal here — the env panel's border comet lights for the
      // whole run (the folder survey AND the main agent; the scouts light
      // their own panels from runStandalone). The finally guarantees a
      // thrown/cancelled run can't leave it stuck on.
      final activity = RunActivity(host);
      resources.own(activity.complete);
      // First load: before the main ceremony, fan out one read-only scout
      // per folder — the repo root and each top-level subfolder — each
      // describing its folder and what type of project it is. The assembled
      // report feeds the task prompt below, so the record's layout section
      // comes from real parallel inspection (and the scouts' prose streams
      // into the same host, visible in the side panel). A warm re-verify
      // skips it: the layout already exists and re-verify is about
      // re-measuring the observed sections.
      final survey = firstLoad
          ? await _surveyFolders(
              scheduler: app.scheduler,
              host: host,
              modelRef: agentModelRef,
              cancelSignal: interaction.cancelSignal,
              project: project,
              sinkFactory: interaction.scoutSinkFactory,
            )
          : null;
      await agent.run(
        history: history,
        userInput: _taskPrompt(
          project,
          firstLoad,
          before.staleReason,
          survey: survey,
        ),
        cancelSignal: interaction.cancelSignal,
      );

      // Finish owned work before recording results or merging usage.
      await resources.dispose();

      return EnvironmentExecutionResult(
        agent.abortedReason == null && _finished(history),
        app.spendLedger,
      );
    });
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

  /// Subfolders surveyed beyond the repo root. One read-only agent per
  /// folder; the cap bounds a first-load's fan-out cost, and the report names
  /// whatever was skipped.
  static const kMaxSurveyFolders = 12;

  /// Scouts run at most this many at a time. A full-width fan-out (12+ live
  /// streams) trips hosted endpoints' per-key rate limits (NIM 429s in the
  /// wild), which killed whole first-load runs; a small batch keeps the
  /// ceremony under the limit while still parallel.
  static const kSurveyConcurrency = 4;

  /// The first-load folder survey: one read-only scout sub-agent per target —
  /// the repository root plus each top-level subfolder — each asked to
  /// describe its folder and what type of project it is. Scouts run (batched,
  /// [kSurveyConcurrency] at a time) on the same model the ceremony uses.
  /// Each scout is silent while it works; when it finishes, its description
  /// is posted into [host] (the side panel) as one labeled block, and a final
  /// dim notice marks the survey done — the hand-off point where the main
  /// environment agent takes over. The assembled answers also become one
  /// markdown report for the main agent's task prompt. Returns null when no
  /// scout succeeded (misconfigured model, cancelled) — the ceremony then
  /// proceeds without a survey rather than failing.
  Future<String?> _surveyFolders({
    required SubAgentScheduler scheduler,
    required HostInterface host,
    required String modelRef,
    Future<void>? cancelSignal,
    required String project,
    AgentSink Function(String dir)? sinkFactory,
  }) async {
    final subdirs = surveyFolders();
    final skipped = subdirs.length > kMaxSurveyFolders
        ? subdirs.sublist(kMaxSurveyFolders)
        : const <String>[];
    final targets = <String>['.', ...subdirs.take(kMaxSurveyFolders)];

    host.showMessage(
      'Surveying folders with read-only sub-agents (repository root'
      '${targets.length > 1 ? ' + ${targets.length - 1} subfolders' : ''})…\n',
      style: HostMessageStyle.dim,
    );

    // Scout sinks: with a [sinkFactory] (the TUI), each scout streams live
    // into its OWN panel — no interleaving, since one agent owns one surface.
    // Without one (headless, tests), scouts run silent and post their
    // finished text below instead.
    final silent = _NoopSink();
    Future<RunAgentResult> runScout(String dir) async {
      for (var attempt = 0; ; attempt++) {
        try {
          final out = await scheduler.runStandalone(
            systemPrompt: _surveyorIdentity,
            task: _surveyorTask(dir),
            modelReference: modelRef,
            cancelSignal: cancelSignal,
            sink: sinkFactory?.call(dir) ?? silent,
            toolProfile: ToolProfile.readOnly,
            includeDelegate: false,
          );
          // One retry on a transient failure (a 429 from the batch above, a
          // dropped stream) — permanent errors return at once.
          if (!out.isError || !out.transient || attempt >= 1) return out;
        } catch (e) {
          if (attempt >= 1) return RunAgentResult.error('$e');
        }
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }

    // Bounded-concurrency map: kSurveyConcurrency workers pull targets off a
    // shared cursor, so results post as they finish without a full fan-out.
    final paneled = sinkFactory != null;
    final results = <({String dir, RunAgentResult out})>[];
    var next = 0;
    Future<void> worker() async {
      while (next < targets.length) {
        final dir = targets[next++];
        final out = await runScout(dir);
        final label = dir == '.' ? 'repository root' : dir;
        // Env-panel progress line: terse when the transcript lives in its own
        // panel, the full description when it doesn't (headless).
        host.showMessage(
          paneled
              ? '── $label: ${out.isError ? 'scout failed (${out.text})' : 'done ✓ (see its panel)'}\n'
              : '── $label: ${out.isError ? 'scout failed (${out.text})' : out.text.trim()}\n',
          style: HostMessageStyle.dim,
        );
        results.add((dir: dir, out: out));
      }
    }

    await Future.wait([
      for (var i = 0; i < kSurveyConcurrency && i < targets.length; i++)
        worker(),
    ]);

    final buf = StringBuffer();
    var succeeded = 0;
    // Target order (root first, then sorted subfolders), not completion
    // order — the report reads top-down like the tree it describes.
    results.sort((a, b) => targets.indexOf(a.dir) - targets.indexOf(b.dir));
    for (final r in results) {
      if (r.out.isError) continue;
      succeeded++;
      buf.writeln('### ${r.dir == '.' ? 'repository root' : r.dir}');
      buf.writeln(r.out.text.trim());
      buf.writeln();
    }
    host.showMessage(
      'Folder survey complete — $succeeded/${results.length} folders '
      'described; environment agent taking over…\n',
      style: HostMessageStyle.dim,
    );
    if (succeeded == 0) return null;
    if (skipped.isNotEmpty) {
      buf.writeln(
        '(folder survey capped at $kMaxSurveyFolders subfolders; '
        'skipped: ${skipped.join(', ')})',
      );
    }
    return buf.toString().trimRight();
  }

  String _surveyorTask(String dir) => dir == '.'
      ? 'Describe the repository at its root: what type of project this is '
            '(language, framework, build system) and what the top-level layout '
            'contains. Read the manifests (pubspec.yaml, package.json, '
            'Cargo.toml, go.mod, pyproject.toml, …) and a few key files. Keep '
            'it to a short paragraph.'
      : 'Describe the folder "$dir": what type of project or content it is '
            '(language, framework, build system, purpose) and what it contains. '
            'Read its manifests and a few key files. Keep it to a short '
            'paragraph.';

  static const _surveyorIdentity = '''
You are a folder surveyor: a read-only sub-agent that describes one folder of a repository. Look at the folder's manifests, config files, and source layout, then answer with one short prose paragraph: what type of project or content the folder holds (language, framework, build system, purpose) and what it contains. Never invent details you did not read; if the folder is trivial (empty, generated, assets only), say so in one line. Your entire answer is quoted verbatim into a report — no preamble, no tool-call recap.''';

  static const _identity = '''
You are the environment agent for this repository. Your job is to establish and maintain the environment every agent here needs: dependencies installed, toolchain present, build and test commands known and working, git identity and GitHub auth configured. You are a doing worker — you run commands, you do not just describe them.

The repo's environment record is .tina/ENVIRONMENT.md at the repo root (inside the gitignored .tina sidecar). It has two kinds of content: intent sections (Toolchain, Setup, Build, Test, Auth — the commands that should be run) and observed sections (the test baseline, "verified at" stamps — what the last run measured). The user may edit anything; treat the intent sections as authoritative and rewrite only the observed sections from your own fresh measurements.

Rules:
- Run the setup: dependency install, build, test. Use bash for commands and write/edit for the record.
- Measure before you claim: run the test suite and record what actually happened (counts, failures). Never invent a baseline.
- Auth entries are references only — never write tokens, passwords, or key material into the record. You may check auth (gh auth status, git config) and load keys (ssh-add); if something needs a typed secret, record "needs user action" instead.
- If a dependency step, command, or tool is missing, add or fix it in the intent sections and note what you changed.
- When the task includes a folder survey, write a Layout section from it: one bullet per top-level folder — its project type and purpose. Trust the scouts' descriptions; re-verify only where one looks wrong.
- Delegate read-only exploration (reading manifests, checking the toolchain) to sub-agents when useful; keep the mutating actions to yourself.

Finish with a short report: what you ran, what passed, what failed, what needs user action.''';

  String _taskPrompt(
    String project,
    bool firstLoad,
    String? staleReason, {
    String? survey,
  }) {
    if (firstLoad) {
      final base =
          'No .tina/ENVIRONMENT.md exists at $project yet. Populate '
          'it from measurements: inspect the dependency manifests and '
          'toolchain, run the setup, build, and tests, check git identity / '
          'SSH key / GitHub auth, then write .tina/ENVIRONMENT.md with the '
          'intent sections '
          '(Setup, Build, Test, Auth references) and the observed sections '
          '(Toolchain observed, Test baseline with real counts, verified-at '
          'stamp with the current commit).';
      if (survey == null) return base;
      return '$base\n\nRead-only scout sub-agents already surveyed the '
          'repository root and each top-level subfolder; their per-folder '
          'descriptions follow. Use them for the Layout section (one bullet '
          'per folder: project type, purpose) instead of walking the tree '
          'yourself.\n\n<folder-survey>\n$survey\n</folder-survey>';
    }
    return 'The environment record is stale${staleReason == null ? '' : ': $staleReason'}. '
        'Re-verify: re-run the setup, build, and tests, check auth, and update '
        'ENVIRONMENT.md (.tina/ENVIRONMENT.md) — the intent sections only '
        'where reality disagrees, '
        'and the observed sections (baseline, verified-at stamp) from fresh '
        'measurements.';
  }
}

/// A sink that swallows everything — the folder survey's scouts run silently
/// and post their finished descriptions instead (see [_surveyFolders]). Same
/// posture as the region agents' silent sink.
class _NoopSink implements AgentSink {
  @override
  void text(String s) {}
  @override
  void newline() {}
  @override
  void toolStart(ToolStartEvent event) {}
  @override
  void toolOutput(ToolOutputEvent event) {}
  @override
  void toolComplete(ToolCompleteEvent event) {}
  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {}
  @override
  void activityStart() {}
  @override
  void activityStop() {}
}
