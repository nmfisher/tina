import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/config/resume_request.dart';
import 'package:tina_app/src/platform/environment.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';
import 'package:tina_app/src/composition/provider_resolution.dart';
import 'package:tina_app/src/composition/runtime_resources.dart';

export 'package:tina_app/src/composition/runtime_resources.dart';

/// The assembled non-UI world shared by every frontend (the interactive TUI and
/// the headless `--prompt` runner): the parsed config, the provider registry,
/// the base permission policy, the session store, the agent pipeline +
/// scheduler, and the resolved initial session. Building it once here means the
/// two entry points can't drift on provider/policy/store wiring — each just
/// reads what it needs.
///
/// The classifier provider is runtime-owned. Conversation providers are
/// caller-owned: the first
/// conversation's is built on demand via [buildStartupProvider], later
/// conversations build their own through the runtime factory (SessionManager's
/// `providerFactory`), and each owner closes what it built.
class AppComposition {
  final RuntimeConfig config;
  final Environment environment;
  final ProviderRegistry registry;
  final LlmProviderFactory providers;
  final PermissionPolicy policy;
  final SessionStore store;
  final AgentPipeline pipeline;
  final SubAgentScheduler scheduler;

  /// Session-scoped spend ledger shared by every agent (main + orchestrator +
  /// all scouts) via the runtime's provider decorator. Exposed so the command
  /// layer can render it (`/spend`).
  final SpendLedger spendLedger;

  /// Session-wide pause gate: when any agent trips its per-session token limit,
  /// this closes (parking every agent) and the TUI shows a continue/abort
  /// dialog. Exposed so the TUI can subscribe to `onPause`.
  final PauseGate pauseGate;

  /// The session/conversation to start from, resolved from `--resume` /
  /// `--continue` (see [resolveSession]). Empty ids + empty
  /// history mean a fresh start.
  final String initialSessionId;
  final String initialConversationId;
  final List<Message> initialHistory;

  /// On resume, the full session manifest (every conversation, with metadata)
  /// so the coordinator can rehydrate all of them. Null for a fresh session.
  final SessionManifest? initialManifest;

  /// Test seam only: when `buildAppComposition` was given a `provider`,
  /// [buildStartupProvider] returns it instead of building a real one. Null in
  /// production. (An injected fake bypasses registry.build, so it isn't
  /// metered — fine for fakes.)
  final LlmProvider? startupProviderOverride;

  /// The "auto" permission mode's safety classifier, built from
  /// `[permissions] model` (or the main model). Null when no provider could
  /// be built — auto mode then falls back to the interactive prompt.
  final PermissionClassifier? classifier;

  final RuntimeResources _resources;

  Future<void> dispose() => _resources.dispose();

  AppComposition({
    required this.config,
    required this.environment,
    required this.registry,
    LlmProviderFactory? providers,
    required this.policy,
    required this.store,
    required this.pipeline,
    required this.scheduler,
    required this.spendLedger,
    required this.pauseGate,
    required this.initialSessionId,
    required this.initialConversationId,
    required this.initialHistory,
    this.initialManifest,
    this.startupProviderOverride,
    this.classifier,
    bool ownsStore = false,
    RuntimeResources? resources,
  }) : providers = providers ?? registry,
       _resources = resources ?? RuntimeResources() {
    if (resources == null) {
      if (ownsStore) _resources.own(store.close);
      if (classifier != null) _resources.own(classifier!.provider.close);
      _resources.own(scheduler.dispose);
    }
  }

  /// Build the FIRST conversation's provider. Not a field: this is
  /// conversation-scoped state, so the caller owns the result and closes it —
  /// the TUI's initial `Conversation`, the headless `--prompt` turn, or the
  /// summary fleet's ephemeral composition. Never share one instance between
  /// two conversations; every caller gets its own. Later conversations don't
  /// call this (SessionManager uses the runtime factory). Metered: the
  /// runtime factory is created in `buildAppComposition` before this runs.
  ///
  /// Model precedence on resume (`--resume` / `--continue`, headless and TUI
  /// alike): an explicit `--model` flag wins; otherwise the ACTIVE
  /// conversation's persisted meta model ref wins (a `/model` swap during the
  /// session would otherwise be lost, and the conversation would come back
  /// under the config default); otherwise the config default. Same resolution
  /// philosophy as the restore fallback (`_restoreProvider` in
  /// session_restore.dart): an unresolvable ref warns on stderr and degrades
  /// to the config provider rather than failing the resume.
  LlmProvider buildStartupProvider() {
    if (_resources.isClosing) throw StateError('Runtime is closing');
    if (startupProviderOverride != null) return startupProviderOverride!;
    // The persisted ref applies only when the user did NOT pass --model.
    if (!config.modelExplicit) {
      final activeMeta = initialManifest?.conversations
          .where((c) => c.id == initialConversationId)
          .firstOrNull;
      final ref = activeMeta?.model;
      if (ref != null &&
          ref.isNotEmpty &&
          ref != '${config.provider}/${config.model}') {
        final refProvider = refProviderForBuild(ref);
        if (refProvider == null || registry.descriptor(refProvider) == null) {
          stderr.writeln(
            'resume: conversation model "$ref" is no longer resolvable — '
            'falling back to ${config.provider}/${config.model}.',
          );
        } else {
          // The startup key/base URL apply only to the CONFIG provider; a
          // different provider resolves afresh from its descriptor + env (same
          // guard as the TUI's providerFactory). buildResolved applies that
          // rule plus the config's tuning knobs.
          return buildResolved(
            providers,
            config,
            ref,
            apiKeyOverride: config.apiKey,
            baseUrlOverride: config.baseUrl,
          );
        }
      }
    }
    return providers.build(
      '${config.provider}/${config.model}',
      apiKeyOverride: config.apiKey,
      baseUrlOverride: config.baseUrl,
      maxTokens: config.maxTokens,
      streamIdleTimeout: config.streamIdleTimeout,
      requestTimeout: config.requestTimeout,
    );
  }
}

/// Assemble the [AppComposition] from a parsed [config] + [registry]: base
/// policy, session store, agent composition, and the resolved initial session.
/// [provider] / [store] are overridable so tests can inject fakes. An injected
/// store is borrowed unless [ownsStore] explicitly transfers ownership.
/// Production
/// leaves them null so `buildStartupProvider` builds the real registry-built
/// provider and the on-disk store is used.
///
/// Argument parsing and the `--help` / parse-error early exits
/// stay at the entry point — they must happen before any provider/store is
/// built. This function takes resolved [config] and an explicit [resumeRequest].
/// A legacy config implementing ResumeRequest is accepted during migration;
/// background runs with plain RuntimeConfig start fresh.
/// [projectRoot] selects the tool sandbox and search root (defaults to cwd).
/// A same-project background run borrows [toolScope] to retain the live tools
/// and write lock; other runs acquire a fresh scope. A borrowed [promptContext]
/// carries the parent runtime's project sources and trust decision.
Future<AppComposition> buildAppComposition({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  LlmProvider? provider,
  SessionStore? store,
  bool ownsStore = false,
  Environment? environment,
  String? projectRoot,
  ProjectToolScope? toolScope,
  ResumeRequest? resumeRequest,
  PromptContext? promptContext,
  bool? loadProjectContext,
}) async {
  final resources = RuntimeResources();
  try {
    final sessionStore = store ?? JsonlSessionStore.defaultLocation();
    if (store == null || ownsStore) resources.own(sessionStore.close);
    final runtime = await buildExecutionRuntime(
      config: config,
      registry: registry,
      environment: environment,
      projectRoot: projectRoot,
      toolScope: toolScope,
      promptContext: promptContext,
      loadProjectContext: loadProjectContext,
    );
    resources.own(runtime.dispose);
    final env = runtime.environment;
    final providers = runtime.providers;
    final policy = runtime.policy;
    final pipeline = runtime.pipeline;
    final scheduler = runtime.scheduler;
    final ledger = runtime.spendLedger;
    final pauseGate = runtime.pauseGate;
    final classifier = runtime.classifier;
    final resolved = await resolveSession(
      resumeRequest ??
          (config is ResumeRequest
              ? config as ResumeRequest
              : const ResumeRequest()),
      sessionStore,
    );
    // Restore the resumed session's recorded token spend into the ledger, so
    // `/spend` shows the true session total across processes. Seeding never
    // trips the ceiling (the cap guards what THIS process spends).
    final manifest = resolved.manifest;
    if (manifest != null && manifest.usageTokens > 0) {
      ledger.seed(manifest.usageTokens);
    }
    return AppComposition(
      config: config,
      environment: env,
      registry: registry,
      providers: providers,
      startupProviderOverride: provider,
      policy: policy,
      store: sessionStore,
      pipeline: pipeline,
      scheduler: scheduler,
      spendLedger: ledger,
      pauseGate: pauseGate,
      initialSessionId: resolved.sessionId,
      initialConversationId: resolved.activeConversationId,
      initialHistory: resolved.activeHistory,
      initialManifest: resolved.manifest,
      classifier: classifier,
      resources: resources,
    );
  } catch (_) {
    try {
      await resources.dispose();
    } catch (_) {}
    rethrow;
  }
}

/// The session resolved for startup. [manifest] is null for a fresh session
/// (nothing on disk yet); on resume it lists every conversation in the session.
/// [activeHistory] is the active conversation's transcript (replayed on startup);
/// the histories of the other conversations are rehydrated by the coordinator.
class ResolvedSession {
  final String sessionId;
  final String activeConversationId;
  final List<Message> activeHistory;
  final SessionManifest? manifest;

  const ResolvedSession({
    required this.sessionId,
    required this.activeConversationId,
    required this.activeHistory,
    this.manifest,
  });
}

/// Resolve the session to use given config flags. Returns the active
/// conversation's id + transcript and, on resume, the full manifest (so the
/// coordinator can rehydrate every conversation, not just the active one).
/// Session and conversation entries are NOT created eagerly — the
/// [SessionRecorder] does that lazily on the first write. An empty session
/// leaves no trace on disk.
Future<ResolvedSession> resolveSession(
  ResumeRequest config,
  SessionStore store,
) async {
  if (config.resumeSessionId != null) {
    final sid = config.resumeSessionId!;
    final manifest = await store.loadSession(sid);
    final resolved = await _loadBestConversation(
      store,
      sid,
      manifest,
      why: 'resume',
    );
    if (resolved == null) {
      // The user named this session explicitly — say what's wrong rather
      // than silently swapping in a fresh one.
      throw StateError(
        'no readable transcript in session $sid — its transcripts are '
        'project-local and the project no longer has them (fresh clone or '
        'git clean?)',
      );
    }
    return resolved;
  }
  if (config.continueLatest) {
    final list = await store.listSessions();
    // Scope to the current folder: a session matches if it recorded no cwd
    // (pre-dates folder tracking — treat as unknown, still eligible) or if its
    // recorded cwd is this directory. `list` is already sorted most-recent
    // first, so the first match is the latest session in this folder.
    final cwd = Directory.current.path;
    final inFolder = list.where((s) => s.cwd == null || s.cwd == cwd).toList();
    // A session whose transcripts are all unreadable (see
    // [_loadBestConversation]) is skipped in favor of the next candidate —
    // crashing on the newest one would make --continue unusable exactly when
    // the user needs it (after a fresh clone / git clean).
    for (final pick in inFolder) {
      final manifest = await store.loadSession(pick.id);
      final resolved = await _loadBestConversation(
        store,
        pick.id,
        manifest,
        why: 'continue',
      );
      if (resolved == null) {
        stderr.writeln(
          '--continue: skipping "${pick.title}" (${pick.id}) — no readable '
          'transcript (project-local transcripts missing; fresh clone or '
          'git clean?)',
        );
        continue;
      }
      // Say what was picked: --continue silently resuming something the user
      // didn't expect is indistinguishable from picking wrong (the newest
      // session is often yesterday's — today's runs may never have persisted,
      // since empty sessions leave no trace). Naming the session, its title,
      // and when it was last active makes the choice verifiable at a glance.
      stderr.writeln(
        '--continue: resuming "${pick.title}" '
        '(last active ${pick.updatedAt.toLocal()}, id ${pick.id})',
      );
      return resolved;
    }
    stderr.writeln(
      '--continue: no saved sessions found in this folder; starting fresh.',
    );
  }
  // Fresh session — generate IDs locally; the SessionRecorder creates the
  // store entries lazily on the first append. No manifest yet.
  return ResolvedSession(
    sessionId: _newId(),
    activeConversationId: _newId(),
    activeHistory: <Message>[],
    manifest: null,
  );
}

/// Load the session's active conversation, falling back to its first
/// READABLE conversation when the active one's transcript is missing, and to
/// null when none load.
///
/// Crash guard (owner bug 2026-08-24: `tina --continue` died with
/// "Conversation not found: <sid>/<cid>"): modern sessions keep transcripts
/// PROJECT-LOCAL (`<cwd>/.tina/sessions/<sid>/`, gitignored) while the
/// manifest lives in the global store — a fresh clone or `git clean` removes
/// every transcript while the manifest survives, and the manifest's
/// `activeConversationId` then names a file that no longer exists anywhere.
/// Startup must degrade — pick what still reads — instead of crashing before
/// the REPL draws.
Future<ResolvedSession?> _loadBestConversation(
  SessionStore store,
  String sid,
  SessionManifest manifest, {
  required String why,
}) async {
  // Deduped, active-first candidate order.
  final ids = <String>{
    if (manifest.activeConversationId.isNotEmpty) manifest.activeConversationId,
    ...manifest.conversations.map((c) => c.id),
  }.toList();
  String? picked;
  List<Message>? history;
  for (final id in ids) {
    try {
      history = await store.loadConversation(sid, id);
      picked = id;
      break;
    } on StateError {
      continue; // transcript missing/unreadable — try the next candidate
    }
  }
  if (picked == null) return null;
  if (picked != manifest.activeConversationId) {
    stderr.writeln(
      '$why: active conversation ${manifest.activeConversationId} is '
      'unreadable — falling back to $picked',
    );
  }
  return ResolvedSession(
    sessionId: sid,
    activeConversationId: picked,
    activeHistory: history ?? <Message>[],
    manifest: manifest,
  );
}

String _newId() {
  final now = DateTime.now();
  final ts =
      '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-'
      '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
  final r = now.millisecondsSinceEpoch ^ now.microsecond;
  final hex = (r & 0xFFFF).toRadixString(16).padLeft(4, '0');
  return '$ts-$hex';
}
