import 'package:tina_app/src/composition/runtime_resources.dart';
import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/composition/agent_composition.dart';
import 'package:tina_app/src/composition/provider_resolution.dart';
import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/session/conversation.dart';
import 'package:tina_app/src/session/session_manager.dart' show HostFactory;

/// Everything needed to rebuild a [Conversation] from a [ConversationMeta]. Built
/// once by the coordinator (which owns the registry, store, scheduler, and the
/// terminal host factory) and threaded into [restoreConversation] for every meta.
class RestoreContext {
  final ProviderRegistry registry;
  final LlmProviderFactory providers;
  final AgentPipeline pipeline;
  final RuntimeConfig config;
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
    LlmProviderFactory? providers,
    required this.pipeline,
    required this.config,
    required this.store,
    required this.scheduler,
    required this.hostFactory,
    required this.sessionId,
    required this.activeConversationId,
    required this.accountProvider,
    this.classifier,
  }) : providers = providers ?? registry;
}

/// Rebuild the exact driver a [meta] describes. [provider] is already resolved
/// (from the meta's model ref, or the account provider as a fallback); [host] is
/// the conversation's sink and the source of its asker.
///
/// A primary conversation rebuilds through [buildAgent], so the scope-selected
/// driver factory (and its contribution surface) applies on resume exactly as
/// on the live path. Non-primary kinds resolve through the scheduler's driver
/// factory with their restored tools and policy, retaining mounted guards and
/// hooks just like live delegated sessions.
AgentDriver _restoreDriver({
  required ConversationMeta meta,
  required LlmProvider provider,
  required HostInterface host,
  required PermissionPolicy policy,
  required PermissionPolicy toolsFrom,
  required RestoreContext ctx,
  required String system,
}) {
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
      // the allow-list it was CREATED with — [toolsFrom], which is the stored
      // policy, because that policy decided the tool set at spawn. Gating is
      // [policy] (this run's), so a spawn created under --yolo resumes with the
      // tools it had but asks before using them. An unknown/empty stored policy
      // yields no tools — the conversation is still replayable. A sub-agent may
      // continue to delegate (inheriting its own identity); spawns and branches
      // are leaves.
      final tools = <Tool>[
        ...(ctx.config.safeMode
            ? stripForSafeMode(ctx.pipeline.tools.toolsFromPolicy(toolsFrom))
            : ctx.pipeline.tools.toolsFromPolicy(toolsFrom)),
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
      return ctx.scheduler.driverFor(
        AgentDriverRequest(
          provider: provider,
          tools: ToolRegistry(tools),
          sink: host,
          policy: policy,
          asker: host.askPermission,
          maxSteps: 25,
          budget: null,
          pauseGate: null,
          system: system,
        ),
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
      ctx.providers,
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

/// The policy a [meta] was CREATED under, when the manifest carries one that
/// still parses. Null otherwise.
///
/// This is no longer the policy a resumed conversation gates with — permissions
/// come from the run doing the resuming (see [restoreConversation], and
/// [_permissionChangeNote] for how the difference is reported). It is kept for
/// one thing: the tool set a spawn, sub-agent or branch was created with, which
/// its stored allow-list is the only record of.
PermissionPolicy? _storedPolicy(ConversationMeta meta) {
  final stored = meta.policy;
  if (stored == null) return null;
  try {
    return PermissionPolicy.fromJson(stored);
  } catch (_) {
    return null;
  }
}

/// One line when a resumed session was created with a different permission
/// posture than this run starts with, so the change is stated rather than
/// silent. Null when there is nothing to say.
///
/// A session started with `--yolo` runs under `--yolo` only if the flag was
/// passed again: the posture is an argument to the run, not a property of the
/// session that was saved.
String? _permissionChangeNote(
    PermissionPolicy? stored, PermissionPolicy fresh) {
  if (stored == null) return null;
  final differences = <String>[
    if (stored.allowAllByDefault && !fresh.allowAllByDefault) '--yolo',
    if (stored.mode != fresh.mode) '--permission-mode ${stored.mode.label}',
    if ('${stored.staticRules}' != '${fresh.staticRules}') '--allow/--deny',
  ];
  if (differences.isEmpty) return null;
  return '  this session was created with ${differences.join(', ')}; it '
      'resumes with the permissions of this run — pass '
      '${differences.length == 1 ? 'it' : 'them'} again to keep the original.\n';
}

/// Rebuild a [Conversation] for [meta] with its exact driver and full history,
/// ready to be resumed. The recorder is *attached* to the existing on-disk
/// conversation (its meta is already persisted), so appends go to the real file
/// without recreating it. The host starts detached (background) unless this is
/// the active conversation — the coordinator routes the active one onto the
/// screen.
///
/// The restored conversation's driver IS what [buildAgent] produced for a
/// primary (the scope-selected factory applies on resume exactly as on the
/// live path); non-primary kinds use the scheduler's selected driver factory.
/// [driverWrapper] is the P5 replacement seam — the same hook
/// [SessionManager] exposes at construction: it receives the restored
/// underlying agent (an adapter's wrapped build, or the plain rebuild) and
/// its result becomes the restored conversation's driver, so a test (or
/// profile) can wrap or replace the driver on resume without editing this
/// coordinator. Null (the default) keeps the built driver as-is.
Future<Conversation> restoreConversation(
  ConversationMeta meta,
  RestoreContext ctx, {
  AgentDriver Function(Agent agent)? driverWrapper,
}) async {
  final provider = _restoreProvider(meta, ctx);
  final resources = RuntimeResources()..own(provider.close);
  try {
    // Permissions come from THIS run, not from the run that created the
    // session: the stored policy is the manifest's record of what the session
    // was created with, and is used below only for the tool set of a
    // spawn/sub-agent. So `--yolo` does not survive a resume unless it is
    // passed again, and neither does a stored mode or command rule.
    final storedPolicy = _storedPolicy(meta);
    final policy = ctx.config.buildPolicy();
    final host = ctx.hostFactory(
      conversationId: meta.id,
      isActive: meta.id == ctx.activeConversationId,
    );
    resources.own(host.dispose);
    // The active conversation is the one the user is looking at, so the notice
    // belongs there and not once per restored side conversation.
    final permissionNote = meta.kind == ConversationKind.primary
        ? _permissionChangeNote(storedPolicy, policy)
        : null;
    if (permissionNote != null) {
      host.showMessage(permissionNote, style: HostMessageStyle.warning);
    }
    final system =
        meta.promptOverride ??
        resolveMainPrompt(
          ctx.pipeline,
          overrides: ctx.config.promptOverrides,
          safeMode: ctx.config.safeMode,
          loadWorkspaceContext: ctx.pipeline.loadWorkspaceContext,
        );
    var driver = _restoreDriver(
      meta: meta,
      provider: provider,
      host: host,
      policy: policy,
      toolsFrom: storedPolicy ?? policy,
      ctx: ctx,
      system: system,
    );

    // providerId is recorded in the session manifest on first write; derive it
    // from the stored ref (or the model the account provider runs under).
    final providerId =
        meta.providerId ??
        (meta.model?.contains('/') == true
            ? meta.model!.split('/').first
            : null) ??
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
        'on disk (session ${ctx.sessionId})',
      );
    }

    final recorder = SessionRecorder(
      ctx.store,
      ctx.sessionId,
      meta.id,
      providerId: providerId,
    );
    // Point at the existing conversation — its meta is already on disk.
    recorder.attach(ctx.sessionId, meta.id);

    // P5 seam: the built driver IS the conversation's driver (the scope-
    // selected factory survives the restore). The optional wrapper replaces
    // the driver when provided — it receives the underlying agent when there
    // is one to give (an adapter's wrapped build); an agent-less driver has
    // nothing to wrap and already IS the replacement, so it is kept as-is.
    final underlying = driver is AgentDriverAdapter ? driver.agent : null;
    return Conversation(
      id: meta.id,
      label: meta.label.isNotEmpty ? meta.label : provider.model,
      provider: provider,
      host: host,
      policy: policy,
      modelReference: meta.model ?? '',
      recorder: recorder,
      initialHistory: history,
      driver: driverWrapper == null || underlying == null
          ? driver
          : driverWrapper(underlying),
    );
  } catch (_) {
    try {
      await resources.dispose();
    } catch (_) {}
    rethrow;
  }
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
  SessionStore store,
  String sessionId,
) async {
  try {
    return await store.loadSession(sessionId);
  } on StateError {
    return null;
  }
}
