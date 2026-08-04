import 'package:tina_engine/tina_engine.dart';

import '../composition/agent_composition.dart';
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

  /// The account provider (built from config) — the fallback when a meta carries
  /// no model ref (old sessions stored only `{id, model:null}`).
  final LlmProvider accountProvider;

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
      resolveSystemPrompt(_roleFor(meta, ctx.pipeline),
          overrides: ctx.config.promptOverrides,
          safeMode: ctx.config.safeMode,
          loadProjectContext: ctx.pipeline.loadProjectContext);

  switch (meta.kind) {
    case ConversationKind.primary:
      // Primary conversations are the interactive main role — a delegator with
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
        system: system,
      );
    case ConversationKind.subAgent:
    case ConversationKind.spawn:
    case ConversationKind.branch:
      // Sub-agents, spawns, and branches run a single role's own tools.
      // Faithfully rebuild the role (its tool set fully determines the agent)
      // plus a nested `delegate` tool when the role can delegate (sub-agent
      // only — branches and spawns are leaves).
      final role = ctx.pipeline.role(meta.targetName!);
      if (role == null) {
        // Unknown role (pipeline changed since the session was saved): fall
        // back to a read-only agent so the conversation is still replayable.
        return Agent(
          provider: provider,
          tools: ToolRegistry([]),
          sink: host,
          policy: policy,
          asker: host.askPermission,
          system: system,
        );
      }
      final tools = <Tool>[
        ...(ctx.config.safeMode ? stripForSafeMode(role.tools) : role.tools),
      ];
      if (meta.kind == ConversationKind.subAgent && role.canDelegate) {
        final ctx2 = AgentToolContext(
          scheduler: ctx.scheduler,
          pipeline: ctx.pipeline,
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
        maxSteps: role.maxSteps ?? 25,
        system: system,
      );
  }
}

/// Resolve the provider a [meta] ran under: its stored model ref when present
/// (so a sub-agent that ran under a tiered model is rebuilt under that same
/// model), otherwise the account provider.
LlmProvider _restoreProvider(ConversationMeta meta, RestoreContext ctx) {
  final ref = meta.model;
  if (ref == null || ref.isEmpty) return ctx.accountProvider;
  try {
    return ctx.registry.build(ref, baseUrlOverride: meta.baseUrl);
  } catch (_) {
    // Unknown/ambiguous model ref (provider removed, typo): fall back to the
    // account provider rather than failing the whole restore.
    return ctx.accountProvider;
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

/// The role a [meta] describes — main for primary, the named role otherwise.
AgentRole _roleFor(ConversationMeta meta, AgentPipeline pipeline) {
  if (meta.kind == ConversationKind.primary) return pipeline.mainRole;
  return pipeline.role(meta.targetName!) ?? pipeline.mainRole;
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
