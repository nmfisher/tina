import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';

import '../config.dart';
import '../pipeline/ask_user_tool.dart';
import '../pipeline/launch_workflow_tool.dart';
import '../pipeline/workflow_supervisor.dart';
import '../regions/region_registry.dart';
import '../regions/region_tools.dart';
import '../summaries/summary_index.dart';

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
  // Thread the user's configured policy to unattended agents (workflow nodes)
  // so the bash decision (--yolo / --allow bash:… / default ask) is inherited
  // rather than blanket-allowed.
  scheduler.basePolicy = config.buildPolicy();
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
  RegionRegistry? regions,
  SummaryIndex? summaryIndex,
  Future<List<Answer>> Function(List<Question>)? askUser,
  // Overrides the agent's permission asker (defaults to the host's). The
  // first-load environment agent runs on a background panel host whose own
  // asker auto-denies; the coordinator passes an attention-queue asker so
  // its bash/write prompts actually reach the user.
  PermissionAsker? asker,
  // The "auto" permission mode's classifier. Non-null wraps the asker with
  // modeAwareAsker so `/permissions auto` decides calls without a modal;
  // null leaves the interactive asker untouched.
  PermissionClassifier? classifier,
  String? system,
  // Optional post-tool-result verifier (improvements log #22a): on a successful
  // `edit`/`write` the agent awaits it and appends its verdict to the tool
  // result the model reads next step. Headless passes a DartAnalyzeVerifier;
  // interactive deliberately passes null (no analyze latency in the loop).
  ToolResultVerifier? resultVerifier,
  /// Write-through observers (#25): awaited by the engine after every history
  /// append (user message, assistant completion, tool-result batch) and once
  /// after a compact (with the final post-compact list). Headless passes the
  /// session recorder's append/replace so each message persists as it is
  /// produced — no end-of-run flush to lose on a crash; interactive sessions
  /// rely on the SessionController's turn-end flush (still safe, just coarser).
  HistoryAppendObserver? onHistoryAppend,
  HistoryReplaceObserver? onHistoryReplace,
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
  // workflow in the background (the run's input/output streams into a live run
  // panel; the chat keeps the launch + completion notices) and stop a running
  // launch. The completion turn is injected by the supervisor's onComplete
  // hook — not returned by the tool.
  if (supervisor != null) {
    tools.add(LaunchWorkflowTool(
        supervisor: supervisor, conversationId: conversationId, sink: host));
    tools.add(StopWorkflowTool(supervisor: supervisor));
  }
  // The region surface, when the coordinator wired a registry: discover /
  // query subfolder-scoped agents primed from the summary sidecar. The query
  // tools run one-shot read-only agents via the scheduler; allocate/forget
  // additionally need the summary index (the fleet summarizes on /index).
  if (regions != null) {
    tools.addAll([
      RepoStructureTool(regions),
      ListRegionsTool(regions),
      ReadSummaryTool(regions),
      QueryRegionTool(regions, scheduler,
          parentReference: '${config.provider}/${provider.model}'),
      BroadcastRegionTool(regions, scheduler,
          parentReference: '${config.provider}/${provider.model}'),
      // allocate/forget exist only when the index does — the fleet that
      // summarizes allocations runs at /index.
      if (summaryIndex != null) AllocateRegionTool(regions),
      if (summaryIndex != null) ForgetRegionTool(regions),
    ]);
  }
  // The question surface, when the coordinator wired an asker: pose
  // multiple-choice questions to the user (↑/↓ option, ←/→ question).
  if (askUser != null) {
    tools.add(AskUserTool(askUser));
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
        // Region discovery + a single region query are cheap one-shot reads —
        // same class as `delegate`, no modal. Allocating is a cheap partition
        // write (the fleet runs only when the user approves at `/index`), so
        // the agent can design a layout freely; broadcast_region (N runs)
        // stays on the default `ask`.
        'repo_structure': PermissionDecision.allow,
        'list_regions': PermissionDecision.allow,
        'read_summary': PermissionDecision.allow,
        'query_region': PermissionDecision.allow,
        'allocate_region': PermissionDecision.allow,
        // ask_user IS the user interaction — no double prompt.
        'ask_user': PermissionDecision.allow,
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

  // The resolved asker, wrapped for permission mode "auto" when a classifier
  // is wired: the wrapper consults effectivePolicy.mode per call, so runtime
  // `/permissions <mode>` switches apply with no rebuild.
  var resolvedAsker = asker ?? host.askPermission;
  if (classifier != null) {
    resolvedAsker = modeAwareAsker(
      policy: effectivePolicy,
      classifier: classifier,
      fallback: resolvedAsker,
      notice: (line) => host.showMessage(line, style: HostMessageStyle.dim),
    );
  }

  return Agent(
    provider: provider,
    tools: agentTools,
    sink: host,
    policy: effectivePolicy,
    asker: resolvedAsker,
    budget: config.buildTokenBudget(),
    pauseGate: scheduler.pauseGate,
    maxSteps: config.maxSteps,
    // The engine fires this MID-turn (estimating the next request before it
    // ships), so long autonomous turns — headless --prompt tasks especially,
    // which have no SessionController to run the between-turns pass — compact
    // instead of drowning in accumulated tool results.
    autoCompactThreshold: config.autoCompactThreshold,
    system: resolvedSystem,
    resultVerifier: resultVerifier,
    onHistoryAppend: onHistoryAppend,
    onHistoryReplace: onHistoryReplace,
  );
}
