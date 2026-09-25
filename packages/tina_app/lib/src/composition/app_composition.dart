import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/config/resume_request.dart';
import 'package:tina_app/src/platform/environment.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';
import 'package:tina_app/src/composition/provider_resolution.dart';
import 'package:tina_app/src/composition/runtime_resources.dart';
import 'package:tina_app/src/execution/input_routes.dart';

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
  final InputRoutes? inputRoutes;
  final PluginScope? pluginScope;

  /// Composition-level P5 replacement seam: the agent-driver factory handed to
  /// [scheduler], which uses it to build the agent loop of every scheduler
  /// spawned agent (delegations and workflow nodes). One choice here governs
  /// every scheduler-built agent; null = the scheduler's built-in driver.
  final AgentDriverFactory? driverFactory;

  /// Composition-level P6 replacement seam: the persistence factory handed to
  /// [scheduler], which uses it to record every sub-agent session transcript.
  /// One choice here governs every session-recording sub-agent; null = the
  /// scheduler's built-in behavior (in-memory-only transcripts).
  final SubAgentPersistenceFactory? persistence;

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

  /// The fallback note from the most recent [buildStartupProvider] call:
  /// why the persisted model ref was not used, when it could not be
  /// resolved. Null when the last build resolved a ref normally or fell
  /// through to the config default (nothing degraded).
  ///
  /// The same line goes to stderr, but stderr is invisible behind the TUI's
  /// alternate screen — the exact condition of the 2026-09-24 "quit and
  /// resume, it's on the default model now" bug. So the TUI coordinator
  /// reads this right after its startup build and shows it as a dim
  /// transcript message instead. Last build wins: each call resets it, so a
  /// caller must read it immediately after its own build (the coordinator
  /// does; the restore tear-off runs later and cannot clobber an
  /// already-displayed note).
  String? _startupModelFallback;

  /// The degradation note from the most recent [buildStartupProvider] call.
  String? get startupModelFallback => _startupModelFallback;

  /// The "auto" permission mode's safety classifier, built from
  /// `[permissions] model` (or the main model). Null when no provider could
  /// be built — auto mode then falls back to the interactive prompt.
  final PermissionClassifier? classifier;

  /// Drafts general-but-safe allow patterns for the approval modal's `[r]`
  /// rewrite choice; shares the classifier's provider. Null when that
  /// provider could not be built — the rewrite then only offers the literal
  /// escaped target.
  final RegexSuggester? regexSuggester;

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
    this.inputRoutes,
    this.pluginScope,
    this.driverFactory,
    this.persistence,
    required this.spendLedger,
    required this.pauseGate,
    required this.initialSessionId,
    required this.initialConversationId,
    required this.initialHistory,
    this.initialManifest,
    this.startupProviderOverride,
    this.classifier,
    this.regexSuggester,
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
  /// to the config provider rather than failing the resume. The warning is
  /// also kept on [startupModelFallback] so a UI without a visible stderr
  /// can surface it (read it right after your own call — the next build
  /// resets it).
  LlmProvider buildStartupProvider() {
    if (_resources.isClosing) throw StateError('Runtime is closing');
    _startupModelFallback = null;
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
          // Not only stderr: transcript hosts surface this note from
          // [startupModelFallback] (stderr is invisible behind the alternate
          // screen). Overwrite per call — each build reflects only its own
          // resolution, never a stale one. (tui_bug 2026-09-24: a resumed
          // session came back under the config default with the only
          // explanation written to stderr nobody could see.)
          _startupModelFallback =
              'resume: conversation model "$ref" is no longer resolvable — '
              'using ${config.provider}/${config.model} (pass '
              '--model "$ref" to force it).';
          stderr.writeln(_startupModelFallback!);
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
/// [workspaceRoot] selects the tool sandbox and search root (defaults to cwd).
/// A same-project background run borrows [toolScope] to retain the live tools
/// and write lock; other runs acquire a fresh scope. A borrowed [promptContext]
/// carries the parent runtime's project sources and trust decision.
/// [plugins] extends the default execution profile; contributions such as
/// input routers and handlers are available to both frontends through this app.
Future<AppComposition> buildAppComposition({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  LlmProvider? provider,
  SessionStore? store,
  bool ownsStore = false,
  Environment? environment,
  String? workspaceRoot,
  WorkspaceToolScope? toolScope,
  ResumeRequest? resumeRequest,
  PromptContext? promptContext,
  bool? loadWorkspaceContext,
  AgentDriverFactory? driverFactory,
  SubAgentPersistenceFactory? persistence,

  /// The conversation-wide pause gate, born in the launcher so composition
  /// plugins can share the runtime's gate (PT0: `configuredExploreProjectPlugin`
  /// receives it) instead of each building its own. Defaults to a fresh gate —
  /// every pre-PT0 caller keeps exactly the pre-existing construction shape.
  PauseGate? pauseGate,
  List<PluginDescriptor> plugins = const [],
}) async {
  final resources = RuntimeResources();
  try {
    // SP1/SP2: when no store is injected and no caller plugin provides one,
    // the default JSONL store is built by the session plugin and resolved
    // from plugin scope after activation — the seam alternative backends
    // bind (a caller plugin providing sessionStoreServiceKey replaces the
    // default; two providers of one key would be an activation error). An
    // injected [store] bypasses the plugin entirely (tests). The launcher's
    // pre-runtime reads (picker, cwd restore, --list) go through the
    // read-only SessionIndex, not a store — see the session-persistence
    // program, SP2. Summary-style runtimes (buildExecutionRuntime direct
    // callers) mount no session plugin at all, so they never build an
    // unused store.
    final providesSessionStore = plugins.any(
      (plugin) => plugin.provides.contains(sessionStoreServiceKey),
    );
    final runtime = await buildExecutionRuntime(
      config: config,
      registry: registry,
      environment: environment,
      workspaceRoot: workspaceRoot,
      toolScope: toolScope,
      promptContext: promptContext,
      loadWorkspaceContext: loadWorkspaceContext,
      driverFactory: driverFactory,
      persistence: persistence,
      pauseGate: pauseGate,
      plugins: [
        if (store == null && !providesSessionStore)
          sessionStorePluginFor(config.sessionStoreProvider,
              root: config.sessionStoreRoot == null
                  ? null
                  : Directory(config.sessionStoreRoot!)),
        ...plugins,
      ],
    );
    resources.own(runtime.dispose);
    final SessionStore sessionStore;
    if (store != null) {
      sessionStore = store;
      if (ownsStore) resources.own(store.close);
    } else {
      final fromScope = runtime.pluginScope.lookup(sessionStoreServiceKey);
      if (fromScope != null) {
        sessionStore = fromScope;
        // Ownership is the plugin's (context.own at build): scope teardown —
        // reached through runtime.dispose above — closes it exactly once.
      } else {
        // Migration fallback: the plugin was not mounted (a caller-supplied
        // profile without it). Keep the pre-SP1 behavior.
        sessionStore = JsonlSessionStore.defaultLocation();
        resources.own(sessionStore.close);
      }
    }
    final env = runtime.environment;
    final providers = runtime.providers;
    final policy = runtime.policy;
    final pipeline = runtime.pipeline;
    final scheduler = runtime.scheduler;
    final ledger = runtime.spendLedger;
    // Not named `pauseGate` — that name is the composition parameter (the
    // launcher's gate, forwarded to the runtime); this is the same instance
    // handed back by the runtime.
    final runtimeGate = runtime.pauseGate;
    final classifier = runtime.classifier;
    final regexSuggester = runtime.regexSuggester;
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
      inputRoutes: runtime.inputRoutes,
      pluginScope: runtime.pluginScope,
      driverFactory: driverFactory,
      persistence: persistence,
      spendLedger: ledger,
      pauseGate: runtimeGate,
      initialSessionId: resolved.sessionId,
      initialConversationId: resolved.activeConversationId,
      initialHistory: resolved.activeHistory,
      initialManifest: resolved.manifest,
      classifier: classifier,
      regexSuggester: regexSuggester,
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
///
/// Staleness guard (quit/resume incident 2026-09-23): a readable anchor is
/// not always the conversation the user was last IN. When a primary sibling's
/// transcript was written AFTER the pointer was last deliberately set
/// (persistSelection), the anchor was left behind — resume the newest-written
/// readable primary instead, say why, and heal the pointer on disk. Ties and
/// deliberately-resumed-back anchors (pointer written after every primary's
/// last write) keep the anchor. Stores without the recency capability (and
/// any probe failure) keep today's anchor-first behavior.
Future<ResolvedSession?> _loadBestConversation(
  SessionStore store,
  String sid,
  SessionManifest manifest, {
  required String why,
}) async {
  final anchor = manifest.activeConversationId;
  // Deduped, anchor-first candidate order; ties in the order the manifest
  // lists them (creation order). Primaries only: the anchor names which MAIN
  // conversation a resume reopens, so sub-agent / spawn / branch panels are
  // never candidates (a legacy anchor naming a panel is skipped like an
  // unreadable one — a primary is resumed instead).
  final byId = {for (final c in manifest.conversations) c.id: c};
  final ids = <String>{
    if (anchor.isNotEmpty) anchor,
    ...manifest.conversations.map((c) => c.id),
  }.where((cid) =>
      byId[cid]?.kind == ConversationKind.primary ||
      (cid == anchor && byId[cid] == null) // corrupt manifest: try, then skip
  ).toList();

  // Which candidates actually read? Transcript files are project-local and
  // can vanish (fresh clone / git clean) while the manifest survives.
  final readable = <String>[];
  final histories = <String, List<Message>>{};
  for (final id in ids) {
    try {
      histories[id] = await store.loadConversation(sid, id);
      readable.add(id);
    } on StateError {
      continue; // transcript missing/unreadable — try the next candidate
    }
  }
  if (readable.isEmpty) return null;

  // Staleness guard: prefer the newest-written READABLE PRIMARY over a
  // left-behind anchor. Only primaries compete — a late sub-agent or
  // `/spawn` panel write is normal (panels outlive focus) and must not
  // hijack the resume slot.
  String picked = readable.first; // the anchor when it reads, else first read
  var whyPicked = '';
  if (store is TimestampedSessionStore) {
    try {
      final stamps = await store.conversationTimestamps(sid);
      final pointerAt = await store.activePointerUpdatedAt(sid);
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      DateTime written(String id) {
        final i = manifest.conversations.indexWhere((c) => c.id == id);
        return (i >= 0 && i < stamps.conversationUpdatedAt.length)
            ? stamps.conversationUpdatedAt[i]
            : epoch;
      }

      final pointerIsNewest = readable.every((id) =>
          id == anchor || !written(id).isAfter(pointerAt));
      if (!pointerIsNewest) {
        bool isPrimary(String id) {
          for (final c in manifest.conversations) {
            if (c.id == id) return c.kind == ConversationKind.primary;
          }
          return false;
        }

        final newerPrimaries = readable
            .where((id) =>
                id != anchor &&
                written(id).isAfter(pointerAt) &&
                isPrimary(id))
            .toList();
        if (newerPrimaries.isNotEmpty) {
          // Newest write wins; the anchor wins a tie so a re-pointed
          // (deliberately resumed) anchor is never displaced by an equal
          // timestamp.
          var best = newerPrimaries.first;
          for (final id in newerPrimaries) {
            if (written(id).isAfter(written(best))) best = id;
          }
          picked = best;
          whyPicked =
              'was written after the last deliberate conversation switch — '
              'resuming it instead of the stale anchor';
        }
      }
    } on StateError {
      // Session vanished or probes unsupported mid-flight — anchor stands.
    } on FileSystemException {
      // mtime unreadable — anchor stands.
    }
  }

  if (picked != anchor && anchor.isNotEmpty) {
    // Two distinct reasons to leave the anchor behind — say which:
    // (a) its transcript is gone (the old crash guard), or (b) it reads but a
    // primary was written after the last deliberate switch (staleness).
    final note = whyPicked.isEmpty
        ? '$why: active conversation $anchor is unreadable — falling back '
            'to $picked'
        : '$why: primary conversation $picked $whyPicked ($anchor was left '
            'behind)';
    stderr.writeln(note);
    // Heal the pointer so the next resume skips this dance.
    try {
      await store.setActiveConversation(sid, picked);
    } on StateError {
      // Session/conversation gone mid-flight — nothing to heal.
    }
  }
  return ResolvedSession(
    sessionId: sid,
    activeConversationId: picked,
    activeHistory: histories[picked] ?? <Message>[],
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
