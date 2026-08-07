import 'dart:async';

import '../llm/message.dart';
import '../llm/provider.dart';
import '../llm/registry.dart';
import '../host/host_interface.dart';
import '../permissions/policy.dart';
import '../permissions/prompt.dart';
import '../persistence/session_store.dart';
import '../tools/delegation_typedefs.dart';
import '../tools/tool.dart';
import 'agent.dart';
import 'agent_event_bus.dart';
import 'agent_pipeline.dart';
import 'agent_quota.dart';
import 'agent_sink.dart';
import 'pause_gate.dart';
import 'sub_agent_sink.dart';
import 'system_prompt.dart';
import 'token_budget.dart';
import 'workflow.dart';

/// Lifecycle of a [SubAgentJob].
enum SubAgentJobStatus { queued, running, done, errored, cancelled;

  /// Done, errored, or cancelled — no further work will happen. Used by the
  /// background tools (`collect`, `continue`) to tell a finished job from one
  /// still churning.
  bool get isTerminal =>
      this == SubAgentJobStatus.done ||
      this == SubAgentJobStatus.errored ||
      this == SubAgentJobStatus.cancelled;
}

/// The outcome a sub-agent returns to its orchestrator: final assistant text
/// (possibly truncated), or an error marker.
class DelegationResult {
  final String content;
  final bool isError;
  const DelegationResult(this.content, {this.isError = false});
  factory DelegationResult.error(String message) =>
      DelegationResult(message, isError: true);
}

/// The result of [SubAgentScheduler.runStandalone]: the role's final answer
/// text, or an error.
class RunAgentResult {
  final String text;
  final bool isError;
  const RunAgentResult(this.text, {this.isError = false});
  factory RunAgentResult.error(String message) =>
      RunAgentResult(message, isError: true);
}

/// The shared configuration every spawning tool (`delegate`, `dispatch`,
/// `continue`) runs with: which scheduler to spawn on, the agent pipeline, the
/// parent agent's `"provider/model"` reference and policy for a sub-agent to
/// inherit, the conversation the spawned jobs belong to, and the nesting depth.
/// Built once by the wiring and threaded through the tools, so the same values
/// aren't repeated (and allowed to drift) at every construction site.
class AgentToolContext {
  final SubAgentScheduler scheduler;
  final AgentPipeline pipeline;
  final String parentReference;
  final PermissionPolicy parentPolicy;
  final String originConversationId;
  final int depth;

  const AgentToolContext({
    required this.scheduler,
    required this.pipeline,
    required this.parentReference,
    required this.parentPolicy,
    required this.originConversationId,
    required this.depth,
  });
}

/// Persists a sub-agent job as its own conversation. Set by the wiring (the
/// coordinator, once the store and session id are known) to enable transcript
/// persistence; null (the default) keeps the historical in-memory-only
/// behavior.
///
/// The factory closes over the [SessionStore] and the parent's **session id**
/// (the scheduler is per-session, so this is stable), keeping the scheduler
/// itself store-agnostic. It receives the job being spawned plus the meta
/// (model ref, policy, system prompt — captured by the scheduler just before
/// the call) and the parent conversation id; it mints the conversation +
/// recorder and returns them. The transcript is written there at the end of the
/// agent run.
typedef SubAgentPersistenceFactory = Future<(String, SessionRecorder)> Function(
  SubAgentJob job, {
  required ConversationMetaInput meta,
  required String parentConversationId,
});

/// Builds the [Agent] for a live-panelized sub-agent AND registers it as a
/// first-class session, so focusing its panel makes it the active conversation.
/// The coordinator supplies it (set on the scheduler once at the composition
/// root); the scheduler derives the run primitives (provider, tools, policy,
/// system prompt, budget) and hands them over, then runs the returned [Agent].
///
/// Returns the built agent for [_runAgent]'s loop. When null (or when the job
/// has no panel host) the old inline build is used and the sub-agent stays
/// telemetry-only. All parameters come from [_runAgent]; see it for semantics.
typedef SubAgentSessionFactory = Agent Function(SubAgentScheduler scheduler,
    SubAgentJob job,
    {required LlmProvider provider,
    required ToolRegistry tools,
    required PermissionPolicy policy,
    required AgentSink sink,
    required HostInterface host,
    required SessionRecorder recorder,
    required String conversationId,
    required String label,
    String? system,
    int? maxSteps,
    TokenBudget? budget,
    PauseGate? pauseGate,
    required void Function(void Function()) wirePanelFocus});

/// A handle to running (or completed) sub-agent work — a *channel* the
/// orchestrator can `send` to repeatedly and `read` from. Cheap to create;
/// owned by the [SubAgentScheduler], not the spawning turn. [result] completes
/// per turn (done / errored / cancelled) — a `send` mints a fresh future;
/// [events] is this channel's tagged [JobAgentEvent] stream.
class SubAgentJob {
  final String id;
  final String label;
  final DelegationTarget target;
  final String originConversationId;
  SubAgentJobStatus status;

  /// The context captured at spawn, so a later `send` can re-run the agent on
  /// its accumulated history under the same model/policy/depth.
  final String parentReference;
  final PermissionPolicy parentPolicy;
  final int depth;

  Completer<DelegationResult> _result;
  AgentEventBus _bus;
  Completer<void> _cancel;

  /// The resolved outcome, set by the scheduler's `_finish` once a turn reaches
  /// a terminal state. Lets `read` report a finished channel synchronously.
  DelegationResult? _resolved;
  DelegationResult? get resolvedResult => _resolved;

  /// An agent channel's conversation history, retained after `agent.run` so a
  /// later `send` can continue it. null for workflows and for channels that
  /// never ran a loop (e.g. provider-build failure).
  List<Message>? _history;
  List<Message>? get history => _history;

  /// The persisted conversation this job's transcript is written to, when the
  /// scheduler has a [SubAgentPersistenceFactory] wired. null until the factory
  /// mints the conversation at spawn time, and for jobs spawned while
  /// persistence is disabled. `_recorder` is attached to the existing file, so
  /// the meta registered at birth is never overwritten.
  String? _conversationId;
  String? get conversationId => _conversationId;
  SessionRecorder? _recorder;
  SessionRecorder? get recorder => _recorder;

  SubAgentJob({
    required this.id,
    required this.label,
    required this.target,
    required this.originConversationId,
    required this.parentReference,
    required this.parentPolicy,
    required this.depth,
    required Completer<DelegationResult> result,
    required AgentEventBus bus,
    required Completer<void> cancel,
  })  : _result = result,
        _bus = bus,
        _cancel = cancel,
        status = SubAgentJobStatus.queued;

  /// The latest turn's outcome — completes once per turn (a `send` mints a new
  /// future). Awaits in `delegate`.
  Future<DelegationResult> get result => _result.future;

  /// This channel's tagged event stream (for UI progress or test inspection).
  Stream<AgentEvent> get events => _bus.events;

  /// Bus this channel emits on. Exposed (it's otherwise private) so the
  /// coordinator can wrap a live-panel host in `BusSink(job.eventBus)` without
  /// reaching into scheduler internals.
  AgentEventBus get eventBus => _bus;

  /// Panel sink supplied by the coordinator when this job is live-panelized.
  /// null (the default) → [_runAgent] uses the telemetry-only [SubAgentSink],
  /// so the sub-agent streams into its parent's chat as progress lines.
  AgentSink? panelSink;

  /// Panel host built by the persistence hook when this job is live-panelized.
  /// Stored as the abstract [HostInterface] (never the concrete renderer host)
  /// so the agent layer never depends on the terminal UI. When non-null,
  /// [_runAgent] hands this to [subAgentSessionFactory] to build a first-class
  /// session; a focused sub-agent panel then becomes the active conversation.
  HostInterface? panelHost;

  /// Installs the focus job on a panel's `onFocus`. Set by the persistence hook
  /// (which owns the concrete panel). The session factory calls it with the
  /// handler that should run when the panel gains focus, so the panel switches
  /// to being the active conversation instead of highlight-only.
  void Function(void Function())? wirePanelFocus;

  /// True once the current turn's cancel has been signalled.
  bool get isCancelled => _cancel.isCompleted;

  /// Signal this channel's current turn only. Idempotent for the turn.
  Future<void> cancel() async {
    if (!_cancel.isCompleted) _cancel.complete();
  }
}

/// Owns long-lived sub-agent jobs for a session. `spawn` kicks off an
/// [Agent.run] as a detached future and returns immediately; the job churns
/// independently of the spawning turn. Concurrency is capped by a semaphore;
/// each job gets its own provider (resolved per-provider via the registry),
/// a policy derived from its role's tools, the role's tool set, and an event bus.
class SubAgentScheduler {
  final ProviderRegistry registry;
  final AgentPipeline pipeline;

  /// `[prompts.<role>]` overrides forwarded to [resolveSystemPrompt] so a
  /// sub-agent's identity can be customized without rebuilding the pipeline.
  final Map<String, String> promptOverrides;

  final AgentQuota quota;
  final int defaultMaxSteps;
  final int resultCharCap;
  final int maxTokens;
  final Duration streamIdleTimeout;
  final Duration requestTimeout;

  /// Per-session token cap applied to each sub-agent's [TokenBudget]. 0 means
  /// uncapped (the historical behavior). Populated from
  /// `config.maxSubAgentTokens` by the composition root.
  final int subAgentBudgetLimit;

  /// Shared pause gate forwarded to every sub-agent so a per-session trip in
  /// any sub-agent pauses ALL agents. Null disables pause behavior (legacy
  /// abort) — the headless path leaves this unset.
  final PauseGate? pauseGate;

  /// `tier → "provider/model"` map. A role with [AgentRole.modelTier] resolves
  /// through this; an unmapped tier is a config error. Empty by default, so a
  /// role without a tier inherits the parent's resolved model.
  final Map<String, String> modelTiers;

  /// Read-only session (`--safe-mode`): when true, `write`/`edit`/`bash` are
  /// stripped from every role's registry before the policy is derived, so the
  /// policy tracks the filtered set automatically.
  final bool safeMode;

  /// Set by the wiring to enable nested delegation. Null (default) means
  /// sub-agents can't spawn further sub-agents.
  NestedDelegateToolBuilder? delegateToolBuilder;

  /// Set by the wiring to persist sub-agent transcripts. Null (default) keeps
  /// the historical in-memory-only behavior (job history discarded on exit).
  SubAgentPersistenceFactory? persistence;

  /// Set by the wiring to make a live-panelized sub-agent a first-class
  /// session. [_runAgent] delegates Agent construction + Conversation
  /// registration to it (building the agent with the panel host's asker so a
  /// focused sub-agent panel becomes the active conversation). Null (default) →
  /// old inline, telemetry-only build. Mirrors [NestedDelegateToolBuilder] and
  /// [persistence]: the wiring sets it once at the composition root.
  SubAgentSessionFactory? subAgentSessionFactory;

  final StreamController<AgentEvent> _merged =
      StreamController<AgentEvent>.broadcast();
  final List<SubAgentJob> _jobs = [];
  final Map<String, StreamSubscription<AgentEvent>> _jobSubs = {};
  int _nextId = 0;
  bool _disposed = false;

  SubAgentScheduler({
    required this.registry,
    required this.pipeline,
    required this.maxTokens,
    required this.streamIdleTimeout,
    required this.requestTimeout,
    AgentQuota? quota,
    int maxConcurrent = 6,
    int maxDepth = 3,
    this.promptOverrides = const <String, String>{},
    this.defaultMaxSteps = 25,
    this.resultCharCap = 16000,
    this.modelTiers = const <String, String>{},
    this.subAgentBudgetLimit = 0,
    this.pauseGate,
    this.safeMode = false,
    this.delegateToolBuilder,
  })  : quota = quota ?? AgentQuota(maxDepth: maxDepth, maxLive: maxConcurrent);

  /// Merged stream of every job's tagged events — the single progress channel
  /// the TUI subscribes to.
  Stream<AgentEvent> get events => _merged.stream;

  /// All jobs (any status), in spawn order.
  List<SubAgentJob> get jobs => List.unmodifiable(_jobs);

  /// Jobs spawned by a given conversation.
  List<SubAgentJob> jobsFor(String conversationId) =>
      _jobs.where((j) => j.originConversationId == conversationId).toList();

  /// Look up a job by id, optionally scoped to a conversation. Returns null if
  /// no such job, or none belonging to [conversation]. The background tools pass
  /// their `originConversationId` so a job from one conversation is invisible to
  /// another.
  SubAgentJob? jobById(String id, {String? conversation}) {
    for (final j in _jobs) {
      if (j.id != id) continue;
      if (conversation != null && j.originConversationId != conversation) {
        continue;
      }
      return j;
    }
    return null;
  }

  /// Resume a finished agent channel by sending [text]: re-runs the agent loop
  /// on the channel's accumulated history under its original context, as a
  /// detached future (non-blocking — `read` the result later). Returns null on
  /// success, or an error string explaining why the send was rejected (still
  /// running, not an agent, no history). One in-flight turn per channel.
  String? send(SubAgentJob job, String text) {
    if (_disposed) return 'scheduler disposed';
    if (!job.status.isTerminal) {
      return 'channel ${job.id} is still ${job.status.name}; `read` it first';
    }
    if (job.target is! AgentRole) {
      return 'channel ${job.id} runs a workflow (can\'t send to a workflow)';
    }
    if (job.history == null || job.history!.isEmpty) {
      return 'channel ${job.id} has no conversation history to continue';
    }
    _rerun(job, text);
    return null;
  }

  /// Mint fresh per-turn state (result future, cancel completer, event bus) and
  /// re-run the agent on the channel's retained history. The id stays stable, so
  /// the orchestrator keeps addressing the same channel across sends.
  void _rerun(SubAgentJob job, String text) {
    job._result = Completer<DelegationResult>();
    job._cancel = Completer<void>();
    job._bus = AgentEventBus();
    _jobSubs[job.id]?.cancel();
    _jobSubs[job.id] = job._bus.events.listen(_merged.add);
    job.status = SubAgentJobStatus.queued;
    unawaited(_run(job, job.target, text, job.parentReference,
        job.parentPolicy, job.depth, job._cancel.future, job.history));
  }

  /// The channel's current state for the `read` tool: its resolved result when
  /// the latest turn finished, or a running/queued status line otherwise.
  String read(SubAgentJob job) {
    final r = job.resolvedResult;
    if (job.status.isTerminal && r != null) {
      return r.isError ? '(error) ${r.content}' : r.content;
    }
    return '${job.id} ${job.label} (${job.status.name})';
  }

  /// Stop a channel: cancel any in-flight turn and drop it from the registry.
  Future<void> close(SubAgentJob job) async {
    await job.cancel();
    _jobs.remove(job);
    _jobSubs.remove(job.id)?.cancel();
  }

  /// The universal primitive. Starts the sub-agent as a detached future and
  /// returns a [SubAgentJob] immediately.
  SubAgentJob spawn({
    required DelegationTarget target,
    required String task,
    required String parentReference,
    required PermissionPolicy parentPolicy,
    required String originConversationId,
    int depth = 0,
    Future<void>? sessionCancelSignal,
    List<Message>? seedHistory,
  }) {
    final id = 'j$_nextId';
    _nextId++;
    final bus = AgentEventBus();
    final result = Completer<DelegationResult>();
    final cancel = Completer<void>();
    final job = SubAgentJob(
      id: id,
      label: target.name,
      target: target,
      originConversationId: originConversationId,
      parentReference: parentReference,
      parentPolicy: parentPolicy,
      depth: depth,
      result: result,
      bus: bus,
      cancel: cancel,
    );

    // Enforce the depth cap at the single chokepoint so no spawn path (the
    // delegate tool, dispatch, a workflow stage) can bypass it by passing an
    // un-incremented depth. The nested delegate tool is *also* withheld from a
    // maxed-out agent in [_toolsFor], but that's only a UX nicety — this is the
    // real guard. Return a pre-errored job (not tracked in [_jobs]) so callers
    // like `delegate` / a workflow stage still resolve cleanly.
    if (!quota.allowsDepth(depth)) {
      job._bus.emit(JobAgentEvent(job.id, job.label,
          NoticeAgentEvent('depth cap', NoticeKind.error)));
      _finish(
          job,
          DelegationResult.error('${target.name}: max nesting depth '
              '(${quota.maxDepth}) exceeded'),
          SubAgentJobStatus.errored);
      return job;
    }

    _jobs.add(job);
    _jobSubs[job.id]?.cancel();
    _jobSubs[job.id] = bus.events.listen(_merged.add);
    if (sessionCancelSignal != null) {
      sessionCancelSignal.whenComplete(job.cancel);
    }

    // Mint a persisted conversation for this job (if persistence is wired) and
    // stash its id + recorder on the job so the transcript can be written at the
    // Detached: must not block returning the job, and a store failure must
    // never fail the spawn. When persistence is wired (agent-role targets),
    // kick off _persistJob and only *then* start _run — so the coordinator's
    // persistence hook can mint the conversation, build the live panel, and set
    // [SubAgentJob.panelSink] before the agent streams into it. spawn() itself
    // stays synchronous and returns the job immediately (callers use it before
    // the run starts), matching its pre-panelization contract.
    final run = () => _run(job, target, task, parentReference, parentPolicy,
        depth, cancel.future, seedHistory);
    if (persistence != null && target is AgentRole) {
      unawaited(_persistJob(job, target, parentReference, parentPolicy,
              originConversationId)
          .then((_) => unawaited(run())));
    } else {
      unawaited(run());
    }
    return job;
  }

  /// Build the `subAgent` meta for [role] and hand it to the persistence
  /// factory to mint a conversation + recorder, which are stashed on [job].
  Future<void> _persistJob(
    SubAgentJob job,
    AgentRole role,
    String parentReference,
    PermissionPolicy parentPolicy,
    String originConversationId,
  ) async {
    final factory = persistence;
    if (factory == null) return;
    final reference = _resolvedReference(role) ?? parentReference;
    final policy = _policyFor(role, parentPolicy);
    final system = resolveSystemPrompt(role,
        overrides: promptOverrides,
        safeMode: safeMode,
        loadProjectContext: pipeline.loadProjectContext);
    // The model ref carries the provider prefix; the stored providerId is just
    // the prefix portion for quick resumption without a registry lookup.
    final providerId = reference.contains('/') ? reference.split('/').first : null;
    final meta = ConversationMetaInput.subAgent(
      model: reference,
      providerId: providerId,
      policy: policy,
      systemPrompt: system,
      targetName: role.name,
      parentConversationId: originConversationId,
    );
    try {
      final (conversationId, recorder) = await factory(
        job,
        meta: meta,
        parentConversationId: originConversationId,
      );
      job._conversationId = conversationId;
      job._recorder = recorder;
    } catch (_) {
      // Persistence is best-effort: a store failure must not fail the spawn or
      // the in-memory job. The transcript stays in memory only.
    }
  }

  Future<void> _run(
    SubAgentJob job,
    DelegationTarget target,
    String task,
    String parentReference,
    PermissionPolicy parentPolicy,
    int depth,
    Future<void> cancelSignal,
    List<Message>? seedHistory,
  ) async {
    // Workflows orchestrate only — no provider, no agent loop, no tools — so
    // they don't hold a concurrency slot. Only agent jobs consume the
    // provider/tool resources the semaphore caps. (If a workflow held a slot
    // while awaiting its stages, maxConcurrent concurrent workflows would each
    // wait for a stage slot they could never get → deadlock.)
    final isWorkflow = target is Workflow;
    if (!isWorkflow) await quota.acquire();
    try {
      if (job.isCancelled || _disposed) {
        _finish(job, DelegationResult.error('cancelled'),
            SubAgentJobStatus.cancelled);
        return;
      }
      job.status = SubAgentJobStatus.running;
      final DelegationResult result;
      if (target is Workflow) {
        result = await _runWorkflow(job, target, task, parentReference,
            parentPolicy, depth, cancelSignal);
      } else if (target is AgentRole) {
        result = await _runAgent(job, target, task, parentReference,
            parentPolicy, depth, cancelSignal, seedHistory);
      } else {
        result = DelegationResult.error('unsupported delegation target');
      }
      if (job.isCancelled) {
        _finish(job, DelegationResult.error('cancelled'),
            SubAgentJobStatus.cancelled);
      } else {
        _finish(
            job,
            result,
            result.isError
                ? SubAgentJobStatus.errored
                : SubAgentJobStatus.done);
      }
    } catch (e) {
      _finish(job, DelegationResult.error(e.toString()),
          SubAgentJobStatus.errored);
    } finally {
      if (!isWorkflow) quota.release();
    }
  }

  /// Runs a [Workflow] as a DAG. Each stage's [WorkflowStage.target] is a direct
  /// reference (a role or nested workflow); a stage runs once its
  /// [WorkflowStage.dependsOn] are satisfied, and its context is its
  /// dependencies' outputs (or the workflow input for a root). Independent ready
  /// stages run concurrently each level (bounded by `maxConcurrent` via
  /// [spawn]'s semaphore). The workflow result is the last stage's output (by
  /// position). A `haltOnFail` error aborts. A stage whose target is itself a
  /// workflow recurses (embedding). Cancel is forwarded to in-flight stages via
  /// [spawn]'s `sessionCancelSignal`.
  Future<DelegationResult> _runWorkflow(
    SubAgentJob job,
    Workflow workflow,
    String input,
    String parentReference,
    PermissionPolicy parentPolicy,
    int depth,
    Future<void> cancelSignal,
  ) async {
    final stages = workflow.stages;
    if (stages.isEmpty) {
      return DelegationResult.error('workflow ${workflow.name}: no stages');
    }

    // Effective ids (explicit or index), rejecting duplicates.
    const inputId = ' input'; // sentinel output key for the workflow input
    final idOf = <int, String>{};
    final ids = <String>{};
    for (var i = 0; i < stages.length; i++) {
      final id = stages[i].id ?? '$i';
      if (!ids.add(id)) {
        return DelegationResult.error(
            'workflow ${workflow.name}: duplicate stage id "$id"');
      }
      idOf[i] = id;
    }

    // Validate dependsOn refs name real stages. (Targets are compile-checked
    // references, so nothing to validate there.)
    for (var i = 0; i < stages.length; i++) {
      final stage = stages[i];
      final deps = stage.dependsOn;
      if (deps != null) {
        for (final ref in deps) {
          if (!ids.contains(ref)) {
            return DelegationResult.error('workflow ${workflow.name}: stage '
                '"${idOf[i]}" depends on unknown stage "$ref"');
          }
        }
      }
    }

    final outputs = <String, String>{inputId: input};

    // A stage's resolved dependency ids: null → prior stage (chain, {} for the
    // first); a list → those ids. Roots (empty deps) consume the workflow input.
    List<String> depsOf(int i) {
      final d = stages[i].dependsOn;
      if (d != null) return d;
      return i == 0 ? const [] : [idOf[i - 1]!];
    }

    String priorWork(int i) {
      final deps = depsOf(i);
      final sources = deps.isEmpty ? const [inputId] : deps;
      final buf = StringBuffer();
      for (final d in sources) {
        buf.write('\n\n--- prior work ---\n${outputs[d]}');
      }
      return buf.toString();
    }

    final remaining = <int>[for (var i = 0; i < stages.length; i++) i];
    while (remaining.isNotEmpty) {
      if (job.isCancelled) return DelegationResult.error('cancelled');
      final ready = remaining
          .where((i) => depsOf(i).every((d) => outputs.containsKey(d)))
          .toList();
      if (ready.isEmpty) {
        return DelegationResult.error('workflow ${workflow.name}: dependency '
            'cycle or unsatisfiable dependsOn');
      }
      // Spawn every ready stage concurrently; each gets its deps' outputs.
      final futures = <Future<(int, DelegationResult)>>[];
      for (final i in ready) {
        final stage = stages[i];
        job._bus.emit(JobAgentEvent(job.id, job.label,
            NoticeAgentEvent('→ ${stage.target.name}', NoticeKind.info)));
        final stageJob = spawn(
          target: stage.target,
          task: '${stage.task}${priorWork(i)}',
          parentReference: parentReference,
          parentPolicy: parentPolicy,
          originConversationId: job.originConversationId,
          depth: depth + 1,
          sessionCancelSignal: cancelSignal,
        );
        futures.add(stageJob.result.then((r) => (i, r)));
      }
      for (final (i, r) in await Future.wait(futures)) {
        outputs[idOf[i]!] = r.content;
        remaining.remove(i);
        if (r.isError && stages[i].haltOnFail) return r;
      }
    }
    return DelegationResult(outputs[idOf[stages.length - 1]!]!);
  }

  Future<DelegationResult> _runAgent(
    SubAgentJob job,
    AgentRole role,
    String task,
    String parentReference,
    PermissionPolicy parentPolicy,
    int depth,
    Future<void> cancelSignal,
    List<Message>? seedHistory,
  ) async {
    final LlmProvider provider;
    final String reference;
    try {
      reference = _resolvedReference(role) ?? parentReference;
      provider = registry.build(
        reference,
        maxTokens: maxTokens,
        streamIdleTimeout: streamIdleTimeout,
        requestTimeout: requestTimeout,
      );
    } catch (e) {
      return DelegationResult.error('failed to build provider: $e');
    }

    // One context for the tools + policy this role runs with. The policy is
    // derived from the role's own tools (plus `delegate` when it can delegate),
    // so a sub-agent may use exactly what it declares — never the parent's
    // allow-list.
    final ctx = AgentToolContext(
      scheduler: this,
      pipeline: pipeline,
      parentReference: reference,
      parentPolicy: _policyFor(role, parentPolicy),
      originConversationId: job.originConversationId,
      depth: depth,
    );
    final tools = _toolsFor(role, ctx, depth);
    // A panelized job has its sink supplied by the coordinator (a BusSink over
    // the panel's host); otherwise fall back to the telemetry-only SubAgentSink
    // that streams progress into the parent's chat.
    final sink = job.panelSink ??
        SubAgentSink(jobId: job.id, label: job.label, bus: job._bus);

    final system = resolveSystemPrompt(role,
        overrides: promptOverrides,
        safeMode: safeMode,
        loadProjectContext: pipeline.loadProjectContext);
    final factory = subAgentSessionFactory;
    // A live-panelized job with a wired factory becomes a first-class session:
    // the coordinator builds its Agent (with the panel host's asker, so tool
    // calls can prompt on the focused panel) and registers the Conversation so
    // focusing the panel makes it the active input target. Otherwise fall back
    // to the telemetry-only inline build (auto-deny asker, no session).
    final agent = factory != null && job.panelHost != null
        ? factory(this, job,
            provider: provider,
            tools: tools,
            policy: ctx.parentPolicy,
            sink: sink,
            host: job.panelHost!,
            recorder: job._recorder!,
            conversationId: job.conversationId!,
            label: job.label,
            system: system,
            maxSteps: role.maxSteps ?? defaultMaxSteps,
            budget: subAgentBudgetLimit == 0
                ? null
                : TokenBudget(perSessionLimit: subAgentBudgetLimit),
            pauseGate: pauseGate,
            wirePanelFocus: job.wirePanelFocus!)
        : _buildDefaultAgent(
            provider: provider,
            tools: tools,
            sink: sink,
            policy: ctx.parentPolicy,
            system: system,
            maxSteps: role.maxSteps ?? defaultMaxSteps,
            budget: subAgentBudgetLimit == 0
                ? null
                : TokenBudget(perSessionLimit: subAgentBudgetLimit),
          );

    // Seed from a prior conversation when present (the `continue` primitive);
    // otherwise start fresh. `agent.run` appends the user turn, so a reseeded
    // leaf replays the prior exchange and continues from it.
    final history =
        seedHistory != null ? List<Message>.from(seedHistory) : <Message>[];
    await agent.run(
      history: history,
      userInput: task,
      cancelSignal: cancelSignal,
    );

    // Retain the grown history so a later `continue` can build on this job too.
    job._history = history;

    // Persist the complete transcript to the job's conversation (if it has one).
    // Completion-time persistence is enough; mid-turn incremental writes are a
    // follow-up. Best-effort: a write failure must not fail the job. `replace`
    // rewrites the whole file atomically, so a `send`/re-run that rewrites the
    // grown history stays consistent.
    final recorder = job._recorder;
    if (recorder != null) {
      try {
        await recorder.replace(history);
      } catch (_) {
        // Ignore: the in-memory result still returns to the orchestrator.
      }
    }

    return _extractResult(role.name, history);
  }

  /// Run a single agent turn for a codergon node with [systemPrompt] as the
  /// agent's identity and [task] as the user message, returning the agent's
  /// final answer text. This is the public seam for the attractor pipeline's
  /// `CodergenBackend`: a node carries its own `system_prompt` + `llm_model`/
  /// `llm_provider` (tin-80ll), so this builds the agent from those instead of
  /// resolving an [AgentRole]. It reuses the scheduler's model resolution and
  /// system-prompt assembly — without a [SubAgentJob], quota, or panel/session.
  ///
  /// Depth is 0 (a top-level pipeline node). [sink] streams the turn's text
  /// (e.g. into the conversation host); [cancelSignal] aborts it. [seedHistory]
  /// is reserved for the `full`-fidelity phase.
  ///
  /// [modelReference] is the node's resolved `"provider/model"` (from
  /// `llm_model`/`llm_provider`); when null, [parentReference] (the
  /// conversation's resolved model) is used.
  Future<RunAgentResult> runStandalone({
    required String systemPrompt,
    required String task,
    String parentReference = '',
    String? modelReference,
    List<Message>? seedHistory,
    Future<void>? cancelSignal,
    required AgentSink sink,
  }) async {
    final LlmProvider provider;
    final String reference;
    try {
      reference = modelReference ?? parentReference;
      provider = registry.build(
        reference,
        maxTokens: maxTokens,
        streamIdleTimeout: streamIdleTimeout,
        requestTimeout: requestTimeout,
      );
    } catch (e) {
      return RunAgentResult.error('failed to build provider: $e');
    }

    // A node agent runs with the full base tool set plus `delegate` (when
    // nesting is wired), so it can work directly AND reach the sub-agent
    // catalog. Identity comes from [systemPrompt]; the model from [reference].
    final base = buildTools(safeMode: safeMode).all;
    final policy = _nodePolicy(base, PermissionPolicy());
    final tools = <Tool>[...base];
    if (delegateToolBuilder != null) {
      final nestedCtx = AgentToolContext(
        scheduler: this,
        pipeline: pipeline,
        parentReference: reference,
        parentPolicy: policy,
        originConversationId: '',
        depth: 1,
      );
      tools.add(delegateToolBuilder!(nestedCtx));
    }

    final system = resolveIdentityPrompt(systemPrompt,
        safeMode: safeMode, loadProjectContext: pipeline.loadProjectContext);
    final agent = Agent(
      provider: provider,
      tools: ToolRegistry(tools),
      sink: sink,
      policy: policy,
      asker: _autoDenyAsker,
      maxSteps: defaultMaxSteps,
      budget: subAgentBudgetLimit == 0
          ? null
          : TokenBudget(perSessionLimit: subAgentBudgetLimit),
      pauseGate: pauseGate,
      system: system,
    );

    final history =
        seedHistory != null ? List<Message>.from(seedHistory) : <Message>[];
    await agent.run(
      history: history,
      userInput: task,
      cancelSignal: cancelSignal,
    );

    final extracted = _extractResult('node', history);
    if (extracted.isError) return RunAgentResult.error(extracted.content);
    return RunAgentResult(extracted.content);
  }

  /// A codergen node agent may use exactly the base tool set plus `delegate`
  /// (when nesting is wired). Derived the same way a role's policy is, so the
  /// registry and the policy never drift.
  PermissionPolicy _nodePolicy(Iterable<Tool> base, PermissionPolicy parent) =>
      PermissionPolicy(
        defaults: {
          for (final t in base) t.schema.name: PermissionDecision.allow,
          if (delegateToolBuilder != null) 'delegate': PermissionDecision.allow,
        },
        rules: parent.staticRules,
      );

  /// Inline, telemetry-only Agent build used when the job has no panel host
  /// (or no [subAgentSessionFactory] is wired). Auto-deny asker, no session
  /// registration — preserves the pre-unification behavior for plain delegated
  /// sub-agents.
  Agent _buildDefaultAgent({
    required LlmProvider provider,
    required ToolRegistry tools,
    required AgentSink sink,
    required PermissionPolicy policy,
    required String system,
    required int maxSteps,
    required TokenBudget? budget,
  }) =>
      Agent(
        provider: provider,
        tools: tools,
        sink: sink,
        policy: policy,
        asker: _autoDenyAsker,
        maxSteps: maxSteps,
        budget: budget,
        pauseGate: pauseGate,
        system: system,
      );

  /// [AgentRole.tools] minus the safe-mode-disabled tools when `--safe-mode` is
  /// on. The single source of truth for both the registry and the derived
  /// policy, so the two never drift.
  Iterable<Tool> _effectiveTools(AgentRole role) =>
      safeMode ? stripForSafeMode(role.tools) : role.tools;

  /// Build the role's tool set directly from [AgentRole.tools], and add a nested
  /// `delegate` tool when nesting is allowed and the role grants it. No base
  /// set to filter — each role brings its own tools.
  ToolRegistry _toolsFor(AgentRole role, AgentToolContext ctx, int depth) {
    final tools = [..._effectiveTools(role)];
    if (depth < quota.maxDepth && role.canDelegate && delegateToolBuilder != null) {
      final nestedCtx = AgentToolContext(
        scheduler: this,
        pipeline: pipeline,
        parentReference: ctx.parentReference,
        parentPolicy: ctx.parentPolicy,
        originConversationId: ctx.originConversationId,
        depth: depth + 1,
      );
      tools.add(delegateToolBuilder!(nestedCtx));
    }
    return ToolRegistry(tools);
  }

  /// Derive a sub-agent's policy from its role: it may use exactly its declared
  /// [AgentRole.tools] (plus `delegate` when [AgentRole.canDelegate]). Anything
  /// else is absent from the policy → `ask` (the unmapped-tool default) → denied
  /// by the auto-deny asker. The parent's static permission rules carry forward;
  /// its allow-list does not.
  PermissionPolicy _policyFor(AgentRole role, PermissionPolicy parent) =>
      PermissionPolicy(
        defaults: {
          for (final t in _effectiveTools(role))
            t.schema.name: PermissionDecision.allow,
          if (role.canDelegate) 'delegate': PermissionDecision.allow,
        },
        rules: parent.staticRules,
      );

  /// Resolve [role]'s model to a `"provider/model"` reference, or null to
  /// inherit [parentReference]. A set [AgentRole.modelTier] maps through
  /// [modelTiers]; an unmapped tier is a config error.
  String? _resolvedReference(AgentRole role) {
    final tier = role.modelTier;
    if (tier == null) return null;
    final ref = modelTiers[tier];
    if (ref == null) {
      throw StateError(
          'unknown model tier "$tier" (known: ${modelTiers.keys.join(', ')})');
    }
    return ref;
  }

  DelegationResult _extractResult(String name, List<Message> history) {
    // A leaf that finished normally ends on an assistant text turn — the agent
    // loop returns the instant a turn carries no tool calls, so that final
    // assistant message *is* the answer. Every other terminal shape (ran out of
    // steps, cancelled mid-loop, a stream that ended on a tool call) leaves the
    // last message as a tool-result user turn or a tool-call assistant turn —
    // never a final answer. We must not scavenge an *earlier* assistant fragment
    // (a mid-reasoning preamble) and present it as the result: report the
    // non-finish honestly so the orchestrator knows the job didn't complete.
    if (history.isEmpty) {
      return DelegationResult.error('$name produced no final answer');
    }
    final last = history.last;
    if (last.role != Role.assistant) {
      return DelegationResult.error(
          '$name did not finish — ran out of steps or was cancelled');
    }
    final buf = StringBuffer();
    for (final b in last.content) {
      if (b is TextBlock) buf.write(b.text);
    }
    if (buf.isEmpty) {
      return DelegationResult.error('$name produced no final answer');
    }
    var text = buf.toString();
    if (text.length > resultCharCap) {
      text = '${text.substring(0, resultCharCap)}… (truncated)';
    }
    return DelegationResult(text);
  }

  void _finish(SubAgentJob job, DelegationResult result,
      SubAgentJobStatus status) {
    job.status = status;
    job._resolved = result;
    if (!job._result.isCompleted) job._result.complete(result);
    job._bus.dispose();
  }

  /// Cancel every live job (session/app teardown).
  Future<void> cancelAll() async {
    for (final job in _jobs) {
      await job.cancel();
    }
  }

  /// Release resources. After this, [events] closes and further spawns are
  /// finished as cancelled.
  Future<void> dispose() async {
    _disposed = true;
    await cancelAll();
    for (final sub in _jobSubs.values) {
      sub.cancel();
    }
    _jobSubs.clear();
    await _merged.close();
  }

  static final PermissionAsker _autoDenyAsker =
      (_) async => PermissionResponse.denyOnce;
}
