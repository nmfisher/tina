import 'package:tina_engine/tina_engine.dart';

import '../config.dart';
import '../pipeline/launch_workflow_tool.dart';
import '../pipeline/workflow_supervisor.dart';

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
/// Both modes share the full file/shell tool set ([buildTools]); what differs
/// is the orchestration surface layered on top:
/// - **true (interactive, the default):** main is the manager loop (see
///   docs/features/manager_loop.md). On top of the file tools it gets the
///   workflow surface (when a [supervisor] is wired: `launch_workflow` +
///   `stop_workflow`), `delegate` + the channel surface (send/receive/close),
///   and image rendering. The shared identity steers it toward launching a
///   workflow for substantial work and reserving direct file edits for small
///   changes.
/// - **false (headless `--prompt`):** main runs as a direct worker with the
///   base tool set (+ the workflow surface when wired) and the un-widened
///   policy. Preserves the pre-pipeline behavior (a non-interactive run does
///   not gain delegate/channel tools).
Agent buildAgent({
  required AgentPipeline pipeline,
  required SubAgentScheduler scheduler,
  required String conversationId,
  required LlmProvider provider,
  required HostInterface host,
  required PermissionPolicy policy,
  required Config config,
  bool withSubAgents = true,
  WorkflowSupervisor? supervisor,
  String? system,
}) {
  // The entry agent's resolved system prompt — also the identity a delegated
  // sub-agent inherits. Resolved once so the agent and the delegation context
  // can't drift (and the recorder's captured prompt matches the live one).
  final resolvedSystem = system ??
      resolveMainPrompt(pipeline,
          overrides: config.promptOverrides,
          safeMode: config.safeMode,
          loadProjectContext: pipeline.loadProjectContext);

  // Base registry both modes share: the full file/shell tool set (write/edit/
  // bash are stripped under --safe-mode). Start from a list so the orchestration
  // tools below can append without re-wrapping the registry.
  var tools = [...buildTools(safeMode: config.safeMode).all];
  // The workflow surface, when the host provides a supervisor: launch a DOT
  // workflow in the background (node progress streams to [host] while it runs)
  // and stop a running launch. The completion turn is injected by the
  // supervisor's onComplete hook — not returned by the tool.
  if (supervisor != null) {
    tools.add(LaunchWorkflowTool(
        supervisor: supervisor, conversationId: conversationId, sink: host));
    tools.add(StopWorkflowTool(supervisor: supervisor));
  }

  final ToolRegistry agentTools;
  final PermissionPolicy effectivePolicy;
  if (withSubAgents) {
    // Interactive main: widen the policy to allow `delegate`, the channel
    // surface (send/receive/close), and image rendering on top of the config
    // policy (which already covers the file tools — read allow, write/edit/bash
    // ask). The delegate/channel tools are attached via one context.
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
        // Cancelling a workflow is harmless and time-sensitive (the agent calls
        // it mid-run, often on the user's request) — no modal. launch_workflow
        // itself stays on the default `ask` (a heavyweight autonomous run
        // deserves the user's approval).
        'stop_workflow': PermissionDecision.allow,
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
      // A sub-agent main delegates to inherits this identity verbatim.
      parentSystemPrompt: resolvedSystem,
    );
    // Interactive main renders images, delegates, and talks on channels, on top
    // of the file tools + workflow launcher shared with headless.
    var reg = ToolRegistry([...tools, RenderTool()]);
    reg = withChannelTools(withDelegateTool(reg, ctx), ctx);
    agentTools = reg;
    effectivePolicy = mainPolicy;
  } else {
    // Headless --prompt: main runs as a direct worker with the base set (+ the
    // workflow surface when wired) and the un-widened policy.
    agentTools = ToolRegistry(tools);
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
    system: resolvedSystem,
  );
}
