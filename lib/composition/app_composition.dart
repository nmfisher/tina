import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import '../config.dart';
import '../platform/environment.dart';
import 'agent_composition.dart';

/// The assembled non-UI world shared by every frontend (the interactive TUI and
/// the headless `--prompt` runner): the parsed config, the provider registry,
/// the startup provider, the base permission policy, the session store, the
/// agent pipeline + scheduler, and the resolved initial session. Building it
/// once here means the two entry points can't drift on provider/policy/store
/// wiring — each just reads what it needs.
class AppComposition {
  final Config config;
  final Environment environment;
  final ProviderRegistry registry;
  final LlmProvider provider;
  final PermissionPolicy policy;
  final SessionStore store;
  final AgentPipeline pipeline;
  final SubAgentScheduler scheduler;

  /// Session-scoped spend ledger shared by every agent (main + orchestrator +
  /// all scouts) via the registry's provider decorator. Exposed so the command
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

  const AppComposition({
    required this.config,
    required this.environment,
    required this.registry,
    required this.provider,
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
  });
}

/// Assemble the [AppComposition] from a parsed [config] + [registry]: startup
/// provider, base policy, session store, agent composition, and the resolved
/// initial session. [provider] / [store] are overridable so tests can inject
/// fakes; production leaves them null to get the real registry-built provider
/// and the on-disk store.
///
/// Config parsing (argv → [Config]) and the `--help` / parse-error early exits
/// stay at the entry point — they must happen before any provider/store is
/// built, so this function takes the already-parsed [config], not argv.
Future<AppComposition> buildAppComposition({
  required Config config,
  required ProviderRegistry registry,
  LlmProvider? provider,
  SessionStore? store,
  Environment? environment,
}) async {
  final env = environment ?? const PlatformEnvironment();
  // The spend ledger is created BEFORE the startup provider so the registry's
  // decorator wraps every provider built from here on — the startup provider,
  // per-conversation providers, and every sub-agent. (An injected test provider
  // bypasses registry.build and so isn't metered, which is fine for fakes.)
  final ledger = SpendLedger(
    maxGlobalTokens: config.maxGlobalTokens,
    requestsPerMinute: config.requestsPerMinute,
  );
  final pauseGate = PauseGate();
  registry.decorator =
      (inner) => MeteringProvider(inner, ledger, pauseGate);
  final startupProvider = provider ??
      registry.build(
        '${config.provider}/${config.model}',
        apiKeyOverride: config.apiKey,
        baseUrlOverride: config.baseUrl,
        maxTokens: config.maxTokens,
        streamIdleTimeout: config.streamIdleTimeout,
        requestTimeout: config.requestTimeout,
      );
  final policy = config.buildPolicy();
  // Confine the shared file tools to the project root + deny the Tina tree,
  // and arm write/edit with atomic writes + backups. Idempotent (may re-run on
  // setup relaunch). Uses the process cwd as the project root.
  configureToolSandbox(
    projectRoot: Directory.current.path,
    env: env.env,
  );
  // Build the store unconditionally — /sessions and /resume still work
  // (read-only), and the recorder gates writes.
  final sessionStore = store ?? JsonlSessionStore.defaultLocation();
  final pipeline = defaultPipeline;
  // One process-global limiter shared by every scheduler this run creates, so
  // the depth and live-agent caps span all sessions/schedulers.
  final quota = AgentQuota(
    maxDepth: config.maxSubAgentDepth,
    maxLive: config.maxSubAgentConcurrency,
  );
  final scheduler = createScheduler(
      config: config,
      registry: registry,
      pipeline: pipeline,
      pauseGate: pauseGate,
      quota: quota);
  final resolved = await resolveSession(config, sessionStore);
  return AppComposition(
    config: config,
    environment: env,
    registry: registry,
    provider: startupProvider,
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
  );
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
  Config config,
  SessionStore store,
) async {
  if (config.resumeSessionId != null) {
    final sid = config.resumeSessionId!;
    final manifest = await store.loadSession(sid);
    final loaded =
        await store.loadConversation(sid, manifest.activeConversationId);
    return ResolvedSession(
      sessionId: sid,
      activeConversationId: manifest.activeConversationId,
      activeHistory: loaded,
      manifest: manifest,
    );
  }
  if (config.continueLatest) {
    final list = await store.listSessions();
    // Scope to the current folder: a session matches if it recorded no cwd
    // (pre-dates folder tracking — treat as unknown, still eligible) or if its
    // recorded cwd is this directory. `list` is already sorted most-recent
    // first, so the first match is the latest session in this folder.
    final cwd = Directory.current.path;
    final inFolder = list.where((s) => s.cwd == null || s.cwd == cwd).toList();
    if (inFolder.isNotEmpty) {
      final sid = inFolder.first.id;
      final manifest = await store.loadSession(sid);
      final loaded =
          await store.loadConversation(sid, manifest.activeConversationId);
      return ResolvedSession(
        sessionId: sid,
        activeConversationId: manifest.activeConversationId,
        activeHistory: loaded,
        manifest: manifest,
      );
    }
    stderr.writeln(
        '--continue: no saved sessions found in this folder; starting fresh.');
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

String _newId() {
  final now = DateTime.now();
  final ts =
      '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-'
      '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
  final r = now.millisecondsSinceEpoch ^ now.microsecond;
  final hex = (r & 0xFFFF).toRadixString(16).padLeft(4, '0');
  return '$ts-$hex';
}
