import 'package:tina_engine/tina_engine.dart';

import '../composition/agent_composition.dart';
import '../composition/provider_resolution.dart';
import '../config.dart';
import '../conversation.dart';
import '../session_manager.dart' show HostFactory;

/// Everything needed to rebuild a [Conversation] from a [ConversationMeta]. Built
/// once by the coordinator (which owns the registry, store, scheduler, and the
/// terminal host factory) and threaded into [restoreConversation] for every meta.
class RestoreContext {
  final ProviderRegistry registry;
  final AgentPipeline pipeline;
  final Config config;
  final SessionStore store;
  final SubAgentScheduler scheduler;
  final HostFactory hostFactory;
  final String sessionId;
  final String activeConversationId;

  /// Builds the account provider (from config) — the fallback when a meta
  /// carries no model ref (old sessions stored only `{id, model:null}`) or a
  /// ref that no longer resolves. A FACTORY, not an instance: every fallback
  /// conversation builds and owns its own provider, so no two conversations
  /// ever share (and double-close) one instance. The coordinator passes
  /// `AppComposition.buildStartupProvider`.
  final LlmProvider Function() accountProvider;

  /// The auto-mode permission classifier, when one was built. Restored
  /// primary conversations wrap their asker with it so `/permissions auto`
  /// keeps working across a resume. Null when no classifier exists.
  final PermissionClassifier? classifier;

  const RestoreContext({
    required this.registry,
    required this.pipeline,
    required this.config,
    required this.store,
    required this.scheduler,
    required this.hostFactory,
    required this.sessionId,
    required this.activeConversationId,
    required this.accountProvider,
    this.classifier,
  });
}

/// Rebuild the exact agent a [meta] describes. [provider] is already resolved
/// (from the meta's model ref, or the account provider as a fallback); [host] is
/// the conversation's sink and the source of its asker.
Agent _restoreAgent({
  required ConversationMeta meta,
  required LlmProvider provider,
  required HostInterface host,
  required PermissionPolicy policy,
  required RestoreContext ctx,
}) {
  final system = meta.promptOverride ??
      resolveMainPrompt(ctx.pipeline,
          overrides: ctx.config.promptOverrides,
          safeMode: ctx.config.safeMode,
          loadProjectContext: ctx.pipeline.loadProjectContext);

  switch (meta.kind) {
    case ConversationKind.primary:
      // Primary conversations are the interactive main agent — a delegator with
      // no file tools. Restored exactly as the live path builds it.
      return buildAgent(
        pipeline: ctx.pipeline,
        scheduler: ctx.scheduler,
        conversationId: meta.id,
        provider: provider,
        host: host,
        policy: policy,
        config: ctx.config,
        withSubAgents: true,
        classifier: ctx.classifier,
        system: system,
      );
    case ConversationKind.subAgent:
    case ConversationKind.spawn:
    case ConversationKind.branch:
      // A sub-agent/spawn/branch conversation's tools are reconstructed from
      // its stored policy's allow-list (that policy fully determined its tool
      // set at spawn). An unknown/empty policy yields no tools — the
      // conversation is still replayable. A sub-agent may continue to delegate
      // (inheriting its own identity); spawns and branches are leaves.
      final tools = <Tool>[
        ...(ctx.config.safeMode
            ? stripForSafeMode(toolsFromPolicy(policy))
            : toolsFromPolicy(policy)),
      ];
      if (meta.kind == ConversationKind.subAgent) {
        final ctx2 = AgentToolContext(
          scheduler: ctx.scheduler,
          pipeline: ctx.pipeline,
          parentSystemPrompt: system,
          parentReference: meta.model ?? '',
          parentPolicy: policy,
          originConversationId: meta.parentConversationId ?? meta.id,
          depth: 0,
        );
        tools.add(DelegateTool(ctx2));
      }
      return Agent(
        provider: provider,
        tools: ToolRegistry(tools),
        sink: host,
        policy: policy,
        asker: host.askPermission,
        maxSteps: 25,
        system: system,
      );
  }
}

/// Resolve the provider a [meta] ran under: its stored model ref when present
/// (so a sub-agent that ran under a tiered model is rebuilt under that same
/// model), otherwise a FRESH account provider from the factory (never a shared
/// instance — the conversation owns and closes its own).
///
/// The ref is built under the CURRENT config — the same rule as
/// [AppComposition.buildStartupProvider] and the TUI's providerFactory: the
/// startup key/base URL apply only when the ref's provider IS the config
/// provider, and the base comes from today's config rather than the
/// [ConversationMeta.baseUrl] captured at creation. That capture is
/// provenance; replaying it made a `base-url` edit in ~/.tina/config
/// invisible to every restored conversation of the session.
LlmProvider _restoreProvider(ConversationMeta meta, RestoreContext ctx) {
  final ref = meta.model;
  if (ref == null || ref.isEmpty) return ctx.accountProvider();
  try {
    // Startup key/base URL apply only when the ref's provider IS the config
    // provider; buildResolved enforces that and plumbs the tuning knobs.
    return buildResolved(
      ctx.registry,
      ctx.config,
      ref,
      apiKeyOverride: ctx.config.apiKey,
      baseUrlOverride: ctx.config.baseUrl,
    );
  } catch (_) {
    // Unknown/ambiguous model ref (provider removed, typo): fall back to a
    // fresh account provider rather than failing the whole restore.
    return ctx.accountProvider();
  }
}

/// Resolve the policy a [meta] ran under: its stored policy (defaults + static
/// rules) when present, otherwise a freshly-built config policy.
PermissionPolicy _restorePolicy(ConversationMeta meta, RestoreContext ctx) {
  final stored = meta.policy;
  if (stored == null) return ctx.config.buildPolicy();
  try {
    return PermissionPolicy.fromJson(stored);
  } catch (_) {
    return ctx.config.buildPolicy();
  }
}

/// Rebuild a [Conversation] for [meta] with its exact agent and full history,
/// ready to be resumed. The recorder is *attached* to the existing on-disk
/// conversation (its meta is already persisted), so appends go to the real file
/// without recreating it. The host starts detached (background) unless this is
/// the active conversation — the coordinator routes the active one onto the
/// screen.
Future<Conversation> restoreConversation(
  ConversationMeta meta,
  RestoreContext ctx,
) async {
  final provider = _restoreProvider(meta, ctx);
  final policy = _restorePolicy(meta, ctx);
  final host = ctx.hostFactory(
    conversationId: meta.id,
    isActive: meta.id == ctx.activeConversationId,
  );
  final agent = _restoreAgent(
    meta: meta,
    provider: provider,
    host: host,
    policy: policy,
    ctx: ctx,
  );

  // providerId is recorded in the session manifest on first write; derive it
  // from the stored ref (or the model the account provider runs under).
  final providerId = meta.providerId ??
      (meta.model?.contains('/') == true ? meta.model!.split('/').first : null) ??
      provider.model;
  // Load the history BEFORE attaching the recorder: if the message file is
  // missing, fail now with a clear error rather than landing in a
  // half-attached recorder. (The coordinator's restore loop catches this and
  // skips the conversation — the clear message is the point.)
  final List<Message> history;
  try {
    history = await ctx.store.loadConversation(ctx.sessionId, meta.id);
  } on StateError {
    throw StateError(
        'Cannot restore conversation ${meta.id}: message history not found '
        'on disk (session ${ctx.sessionId})');
  }

  final recorder = SessionRecorder(ctx.store, ctx.sessionId, meta.id,
      providerId: providerId);
  // Point at the existing conversation — its meta is already on disk.
  recorder.attach(ctx.sessionId, meta.id);

  return Conversation(
    id: meta.id,
    label: meta.label.isNotEmpty ? meta.label : provider.model,
    agent: agent,
    provider: provider,
    host: host,
    policy: policy,
    recorder: recorder,
    initialHistory: history,
  );
}

/// The working directory a resumed session should restore to, or null when
/// there is none to restore.
///
/// On `--resume <id>` the launcher chdirs to this value *before* building the
/// project context (trust, AGENTS.md, repo summary, tool sandbox, env agent),
/// so that context resolves against the folder the session actually lives in —
/// not wherever tina happened to be launched from. `--continue` is folder-
/// scoped by design (it only matches sessions whose recorded cwd is the launch
/// folder), so it needs no chdir.
///
/// This function is deliberately pure — it only reads the manifest; it never
/// changes [Directory.current] — so it is unit-testable without a process-global
/// side effect. A missing/unknown session yields null (rather than rethrowing)
/// so the caller can let [resolveSession]'s load surface the real "session not
/// found" error instead of a double fault here.
Future<String?> resumeCwdFor(SessionStore store, String sessionId) async {
  final manifest = await _safeLoadSession(store, sessionId);
  // `null` manifests (session not found, or unknown to this store impl) yield
  // null cwd — the caller lets resolveSession surface the real error.
  return manifest?.cwd;
}

/// Load a session's manifest without throwing when the session is unknown, so a
/// bad/missing `--resume` id degrades to "restore in the launch folder" instead
/// of crashing before the TUI ever starts. A genuinely unknown session is still
/// surfaced by [resolveSession] (which calls loadSession directly) later in the
/// boot path, so swallowing only the documented "not found" error here is safe.
Future<SessionManifest?> _safeLoadSession(
    SessionStore store, String sessionId) async {
  try {
    return await store.loadSession(sessionId);
  } on StateError {
    return null;
  }
}
