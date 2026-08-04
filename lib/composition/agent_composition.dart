import 'package:tina_engine/tina_engine.dart';

import '../config.dart';

/// Build the session-scoped [SubAgentScheduler] over [pipeline], wired to
/// [registry]. Tool/model/budget settings come from [config]; the shared pause
/// gate is forwarded to every sub-agent. The nested-delegation hook is set so a
/// role with `canDelegate` can fan out further (capped by the scheduler's
/// maxDepth). Pass a non-default [pipeline] to reuse the wiring in tests.
SubAgentScheduler createScheduler({
  required Config config,
  required ProviderRegistry registry,
  required AgentPipeline pipeline,
  AgentQuota? quota,
  PauseGate? pauseGate,
}) {
  final scheduler = SubAgentScheduler(
    registry: registry,
    pipeline: pipeline,
    promptOverrides: config.promptOverrides,
    maxTokens: config.maxTokens,
    streamIdleTimeout: config.streamIdleTimeout,
    requestTimeout: config.requestTimeout,
    modelTiers: config.modelTiers,
    subAgentBudgetLimit: config.maxSubAgentTokens,
    pauseGate: pauseGate,
    safeMode: config.safeMode,
    quota: quota,
  );
  scheduler.delegateToolBuilder = (ctx) => DelegateTool(ctx);
  return scheduler;
}

/// Build an [Agent] for one conversation from [pipeline]'s main role.
///
/// [withSubAgents] splits main's two modes:
/// - **true (interactive):** main is a planner/delegator. Its tool registry is
///   `delegate` + the channel surface only — NO file tools, structurally, so
///   main's prompt ("you do not read, write or edit files directly") is a
///   guarantee, not a hope. `mainRole.tools` is empty.
/// - **false (headless `--prompt`):** main runs as a direct worker with the
///   full base tool set ([buildTools]) and the un-widened policy — the one mode
///   where main edits files. Preserves the pre-pipeline behavior (a
///   non-interactive run does not gain delegate/channel tools).
Agent buildAgent({
  required AgentPipeline pipeline,
  required SubAgentScheduler scheduler,
  required String conversationId,
  required LlmProvider provider,
  required HostInterface host,
  required PermissionPolicy policy,
  required Config config,
  bool withSubAgents = true,
  String? system,
}) {
  final ToolRegistry agentTools;
  final PermissionPolicy effectivePolicy;
  if (withSubAgents) {
    // Interactive main delegates — no file tools. Its policy widens to allow
    // `delegate` plus the channel surface (send/receive/close) on top of the
    // config policy; the delegate/channel tools are attached via one context.
    final mainPolicy = PermissionPolicy(
      defaults: {
        ...policy.defaults,
        'delegate': PermissionDecision.allow,
        'send': PermissionDecision.allow,
        'receive': PermissionDecision.allow,
        'close': PermissionDecision.allow,
        // render_image is a pure view-side-effect (paint a local image into the
        // panel); allow it without prompting, like the channel tools.
        'render_image': PermissionDecision.allow,
      },
      rules: policy.staticRules,
    );
    final ctx = AgentToolContext(
      scheduler: scheduler,
      pipeline: pipeline,
      parentReference: '${config.provider}/${provider.model}',
      parentPolicy: mainPolicy,
      originConversationId: conversationId,
      depth: 0,
    );
    // Interactive main delegates — no file tools — but can render images via the
    // shared /image path (RenderTool is a no-op in headless, where it isn't
    // registered).  Delegation + channels are layered on top.
    agentTools = withChannelTools(
        withDelegateTool(ToolRegistry([RenderTool()]), ctx), ctx);
    effectivePolicy = mainPolicy;
  } else {
    // Headless --prompt: main runs as a direct worker with the full base set
    // (minus write/edit/bash under --safe-mode).
    agentTools = buildTools(safeMode: config.safeMode);
    effectivePolicy = policy;
  }

  return Agent(
    provider: provider,
    tools: agentTools,
    sink: host,
    policy: effectivePolicy,
    asker: host.askPermission,
    budget: config.buildTokenBudget(),
    pauseGate: scheduler.pauseGate,
    maxSteps: config.maxSteps,
    system: system ??
        resolveSystemPrompt(pipeline.mainRole,
            overrides: config.promptOverrides,
            safeMode: config.safeMode,
            loadProjectContext: pipeline.loadProjectContext),
  );
}
