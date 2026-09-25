import 'package:attractor/attractor.dart';
import 'live_quotas.dart';
import 'orchestrator_tools.dart';
import '../exploration/explore_project_tool.dart';
import '../plans/plan_plugin.dart' as plans;
import '../goals/goal_plugin.dart' as goals;
import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/workflows/ask_user_tool.dart';
import 'package:tina_app/src/workflows/launch_workflow_tool.dart';
import 'package:tina_app/src/workflows/workflow_supervisor.dart';
import 'package:tina_app/src/regions/region_registry.dart';
import 'package:tina_app/src/regions/region_tools.dart';
import 'package:tina_app/src/summaries/summary_index.dart';

export 'orchestrator_tools.dart';

/// Build the session-scoped [SubAgentScheduler] over [pipeline], wired to
/// [registry]. Tool/model/budget settings come from [config]; the shared pause
/// gate is forwarded to every sub-agent. The nested-delegation hook is set so a
/// role with `canDelegate` can fan out further (capped by the scheduler's
/// maxDepth). Pass a non-default [pipeline] to reuse the wiring in tests.
///
/// [driverFactory] / [persistence] mount the composition-level P5/P6
/// replacement seams (see [AppComposition.driverFactory] /
/// [AppComposition.persistence]): null (the default) keeps the built-in agent
/// loop and the in-memory-only sub-agent transcripts.
SubAgentScheduler createScheduler({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  LlmProviderFactory? providers,
  required AgentPipeline pipeline,
  AgentQuota? quota,
  PauseGate? pauseGate,
  AgentDriverFactory? driverFactory,
  SubAgentPersistenceFactory? persistence,

  /// Plugin-scope contributions resolved at the composition boundary
  /// (execution_runtime.dart) and threaded to their consumers. Null (the
  /// default) means no plugin contributed any — the built-ins run bare.
  /// Empty-by-default keeps every caller that has no plugin runtime
  /// byte-identical to the pre-plugin wiring.
  List<ToolGuard>? guards,
  List<ToolExecutionHook>? executionHooks,
  List<ToolCheck>? toolChecks,
  List<ToolResultHook>? resultHooks,
  List<ToolObserver>? observers,
  PluginScope? scope,
}) {
  final scheduler = SubAgentScheduler(
    registry: registry,
    providers: providers,
    pipeline: pipeline,
    promptOverrides: config.promptOverrides,
    maxTokens: config.maxTokens,
    streamIdleTimeout: config.streamIdleTimeout,
    requestTimeout: config.requestTimeout,
    subAgentBudgetLimit: config.maxSubAgentTokens,
    pauseGate: pauseGate,
    safeMode: config.safeMode,
    quota: quota,
    driverFactory: driverFactory,
  );
  scheduler.budgetFactory = scope
      ?.lookup(liveQuotasServiceKey)
      ?.delegatedBudget;
  scheduler.delegateToolBuilder = (ctx) => DelegateTool(ctx);
  // Thread the user's configured policy to unattended agents (workflow nodes)
  // so the bash decision (--yolo / --allow bash:… / default ask) is inherited
  // rather than blanket-allowed.
  scheduler.basePolicy = config.buildPolicy();
  // Sub-agent transcript persistence is a wiring-set field on the scheduler
  // (not a constructor param) — mount the composition-level choice the same
  // way. null = the scheduler's default in-memory-only behavior.
  scheduler.persistence = persistence;
  // Plugin contributions resolved from the active scope: mounted on the
  // scheduler (engine-side carrier, see [SubAgentScheduler.mountScopeContributions])
  // so every delegated driver build receives them. Lists default to null —
  // no contribution, no behavior change. The scope itself is mounted too: it
  // is the source of profile-mounted prompt sections for delegated identity
  // resolution ([SubAgentScheduler.scopePromptContributors]).
  scheduler.mountScopeContributions(
    guards: guards,
    executionHooks: executionHooks,
    toolChecks: toolChecks,
    resultHooks: resultHooks,
    observers: observers,
  );
  scheduler.mountedScope = scope;
  return scheduler;
}

/// Build the driver for one conversation from [pipeline]'s main role.
///
/// The returned [AgentDriver] is the unit of execution: callers hand it to
/// the [Conversation] and run turns through it — they never unwrap an
/// [Agent] from it (the contract does not even promise one).
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
AgentDriver buildAgent({
  required AgentPipeline pipeline,
  required SubAgentScheduler scheduler,
  required String conversationId,
  required LlmProvider provider,
  required HostInterface host,
  required PermissionPolicy policy,
  required RuntimeConfig config,
  bool withSubAgents = true,

  /// Fixed role capability boundary, independent of live permission mode.
  AgentToolAccess toolAccess = AgentToolAccess.standard,
  WorkflowSupervisor? supervisor,
  RegionRegistry? regions,
  SummaryInspection? summaryIndex,
  Future<List<Answer>> Function(List<Question>)? askUser,
  // Optional permission adapter; defaults to the conversation host's asker.
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

  /// Turn-level transport retries (#28) — opt-in so the TUI's conversation
  /// construction is untouched by default. The HEADLESS runner passes
  /// `config.transportRetryAttempts` (5 unless --transport-retry-attempts
  /// overrides/disables it); every other caller keeps the engine default of 0
  /// (a mid-stream transport error aborts the turn, pre-#28 behavior).
  int transportRetryAttempts = 0,
}) {
  // The entry agent's resolved system prompt — also the identity a delegated
  // sub-agent inherits. Resolved once so the agent and the delegation context
  // can't drift (and the recorder's captured prompt matches the live one).
  // Profile-mounted prompt sections ([scope]'s PromptContributor
  // registrations) trail the built-in blocks in the assembled prompt.
  final resolvedSystem =
      system ??
      resolveMainPrompt(
        pipeline,
        overrides: config.promptOverrides,
        safeMode: config.safeMode,
        loadWorkspaceContext: pipeline.loadWorkspaceContext,
        scope: scheduler.mountedScopeValue,
        workflowEnabled: config.enableWorkflow,
      );

  // Base registry both modes share: the full file/shell tool set (write/edit/
  // bash are stripped under --safe-mode). Start from a list so the orchestration
  // tools below can append without re-wrapping the registry.
  //
  // PT0: `explore_project` rides the mounted execution scope
  // ([exploreProjectToolServiceKey], provided by the launcher's
  // `configuredExploreProjectPlugin`) instead of a hand-threaded parameter —
  // the same lookup every other scope-provided tool rides. The scope is
  // per-process, so one shared tool instance serves every conversation of the
  // session; sub-agents are unchanged (they read [pipeline.tools], which is
  // the mounted tool scope, and the orchestrator role re-reads the key below).
  final exploreProject = scheduler.mountedScopeValue
      ?.lookup(exploreProjectToolServiceKey)
      as ExploreProjectTool?;
  var tools = [
    ...pipeline.tools.buildTools(safeMode: config.safeMode).all,
    if (exploreProject != null) exploreProject,
  ];
  // The plugin-scope plan store (when a plan plugin is mounted) contributes a
  // per-conversation update_plan tool (LocalControlTool: no approval ask) and
  // a request middleware that injects the conversation's plan as agent
  // context. Per-conversation by construction: a shared scope cannot know
  // which conversation a turn belongs to, so these are minted here, keyed by
  // [conversationId].
  final planStore =
      scheduler.mountedScopeValue?.lookup(plans.planStoreServiceKey);
  AgentMiddleware? planMiddleware;
  if (planStore != null) {
    // The plan-approval gate is a human gate, so both per-conversation
    // pieces read the same two signals: the policy's yolo posture
    // (--yolo documents "skip all permission prompts") and whether the host
    // has an answerable human (headless --prompt/--workflow has neither a
    // /plan nor an overlay). Under either, a `requested` ask auto-grants
    // instead of parking the run — the 2026-09-24 unattended stall.
    tools.add(plans.PlanTool(
      planStore,
      conversationId,
      policy: policy,
      host: host,
    ));
    planMiddleware = plans.PlanMiddleware(
      planStore,
      conversationId,
      policy: policy,
      host: host,
    );
  }
  // The plugin-scope goal store (when a goal plugin is mounted) contributes
  // only a request middleware that injects the conversation's goal — the goal
  // has no agent write surface (the user owns it via /goal) and the judge
  // runs outside the agent build (host turn wiring). Per-conversation by the
  // same construction as the plan store above.
  final goalStore =
      scheduler.mountedScopeValue?.lookup(goals.goalStoreServiceKey);
  AgentMiddleware? goalMiddleware;
  if (goalStore != null) {
    goalMiddleware = goals.GoalMiddleware(goalStore, conversationId);
  }
  // The workflow surface, when the host provides a supervisor: launch a DOT
  // workflow in the background (the run's input/output streams into a live run
  // panel; the chat keeps the launch + completion notices) and stop a running
  // launch. The completion turn is injected by the supervisor's onComplete
  // hook — not returned by the tool.
  //
  // Off unless `[features] workflow = true` / `--enable-workflow`: the surface
  // ships disabled (see [RuntimeConfig.enableWorkflow]), so the tools simply do
  // not exist for the agent. Gating here — not at the supervisor's
  // construction — keeps this the single place a tool set is decided, so the
  // headless path and every later session inherit the same answer.
  if (supervisor != null && config.enableWorkflow) {
    tools.add(
      LaunchWorkflowTool(
        supervisor: supervisor,
        conversationId: conversationId,
        sink: host,
      ),
    );
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
      QueryRegionTool(
        regions,
        scheduler,
        parentReference: '${config.provider}/${provider.model}',
        originConversationId: conversationId,
      ),
      BroadcastRegionTool(
        regions,
        scheduler,
        parentReference: '${config.provider}/${provider.model}',
        originConversationId: conversationId,
      ),
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
      modeSource: policy,
      // Interactive main agent: `--yolo`'s posture rides along so the copy
      // keeps it. Under --yolo even the tools left off this table (e.g.
      // launch_workflow, broadcast_region) resolve allow — that is the flag's
      // documented contract ("default every tool to allow"); without the
      // flag they stay ask as before.
      allowAllByDefault: policy.allowAllByDefault,
      // Carry an already-wired classifier gate; when this copy is the one
      // wrapped below, modeAwareAsker sets the flag itself.
      classifierGatesShell: policy.classifierGatesShell,
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
    var reg = ToolRegistry([
      ...tools,
      RenderTool(renderer: pipeline.imageRenderer),
    ]);
    reg = withChannelTools(withDelegateTool(reg, ctx), ctx);
    agentTools = reg;
    effectivePolicy = mainPolicy;
  } else {
    // Headless --prompt: main runs as a direct worker with the base set (+ the
    // workflow surface when wired) and the un-widened policy.
    agentTools = ToolRegistry(tools);
    effectivePolicy = policy;
  }

  // A static permission rule for a tool that is not mounted can never match
  // anything, so it is silently inert: `--deny 'bashh:rm *'`, or a rule for a
  // plugin tool this project does not expose, would look like it was enforcing
  // something. Report each one once, for the MAIN interactive build only (the
  // rule list is global, so a per-sub-agent repeat would just be noise).
  if (withSubAgents) {
    final mounted = {for (final t in agentTools.all) t.schema.name};
    final inert = effectivePolicy.inertRules(mounted);
    if (inert.isNotEmpty) {
      host.showMessage(
        '  ${inert.length} permission '
        '${inert.length == 1 ? 'rule names a tool' : 'rules name tools'} that '
        '${inert.length == 1 ? 'is' : 'are'} not available here, so '
        '${inert.length == 1 ? 'it' : 'they'} can never match:\n'
        '${inert.map((r) => '    ${r.toolName}:${r.pattern}${r.isRegex ? ' (regex)' : ''} '
            '(${r.decision.name})\n').join()}'
        '  Check the spelling, or the project capabilities the tool needs.\n',
        style: HostMessageStyle.warning,
      );
    }
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

  // Fix (P1): main-agent construction goes through the SAME resolved
  // dependencies delegated agents use — the scope-selected driver factory and
  // the mounted scope contributions (guards, hooks, observers). Building
  // `Agent` directly here let a plugin-selected factory, its guards, and its
  // hooks be skipped entirely for the main agent (probes: zero guard
  // invocations, zero factory calls on the main path).
  final request = AgentDriverRequest(
    provider: provider,
    tools: toolAccess == AgentToolAccess.orchestrator
        ? orchestratorTools(
            AskUserTool(askUser),
            exploreProject: exploreProject,
          )
        : agentTools,
    sink: host,
    policy: effectivePolicy,
    asker: resolvedAsker,
    budget:
        scheduler.mountedScopeValue
            ?.lookup(liveQuotasServiceKey)
            ?.mainBudget() ??
        config.buildTokenBudget(),
    pauseGate: scheduler.pauseGate,
    maxSteps: config.maxSteps,
    system: toolAccess == AgentToolAccess.orchestrator
        ? '$resolvedSystem\nYou are an orchestrator without filesystem or shell '
              'access. Use explore_project for repository evidence when available. '
              'Treat per-file judgments as probabilities, not source excerpts. Report coverage gaps. '
              'Do not claim to have inspected files beyond supplied evidence.'
        : resolvedSystem,
    // The scope contributions mounted for this scheduler ride along, so the
    // main build runs under the same guards/hooks/observers as delegates.
    executionGuards: [
      if (toolAccess == AgentToolAccess.orchestrator)
        const OrchestratorToolGuard(),
      ...scheduler.scopeGuards,
    ],
    executionHooks: scheduler.scopeExecutionHooks,
    toolChecks: scheduler.scopeToolChecks,
    middleware: scheduler.mountedScopeValue == null &&
            planMiddleware == null &&
            goalMiddleware == null
        ? null
        : AgentMiddlewarePipeline(
            scope: scheduler.mountedScopeValue,
            middleware: [
              if (planMiddleware != null) planMiddleware,
              if (goalMiddleware != null) goalMiddleware,
            ],
          ),
    promptContext: pipeline.promptContext,
    resultHooks: scheduler.scopeResultHooks,
    observers: scheduler.scopeObservers,
    resultVerifier: resultVerifier,
    onHistoryAppend: onHistoryAppend,
    onHistoryReplace: onHistoryReplace,
    transportRetryAttempts: transportRetryAttempts,
    autoCompactThreshold: config.autoCompactThreshold,
  );
  final factory = scheduler.driverFactory ?? const DefaultAgentDriverFactory();
  final driver = factory.create(request);

  // The driver IS the result — the caller's Conversation runs turns through
  // it. Returning `driver.agent` here (the pre-fix behavior) discarded the
  // replacement driver: every caller executed the built-in agent loop and the
  // driver seam never ran in production. The default pairing is still the
  // adapter over the plain build, so the no-factory behavior is unchanged.

  // A replacement factory gets its contribution surface mirrored onto the
  // scheduler, so delegated builds observe the same contributions the main
  // build was created with.
  if (driver is! AgentDriverAdapter) {
    scheduler.mountScopeContributions(
      // Role restrictions belong to this driver, not sibling conversations.
      guards: scheduler.scopeGuards,
      executionHooks: request.executionHooks,
      toolChecks: request.toolChecks,
      resultHooks: request.resultHooks,
      observers: request.observers,
    );
  }

  return driver;
}
