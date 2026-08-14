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
/// text, or an error. An error with [transient] set (a provider build/stream
/// failure) may clear on its own, so callers may retry it; budget/steps
/// exhaustions and cancellations are permanent.
class RunAgentResult {
  final String text;
  final bool isError;
  final bool transient;
  const RunAgentResult(this.text,
      {this.isError = false, this.transient = false});
  factory RunAgentResult.error(String message, {bool transient = false}) =>
      RunAgentResult(message, isError: true, transient: transient);
}

/// The shared configuration every spawning tool (`delegate`, `dispatch`,
/// `continue`) runs with: which scheduler to spawn on, the agent pipeline, the
/// parent agent's `"provider/model"` reference and policy for a sub-agent to
/// inherit, the parent's *resolved system prompt* (the identity a sub-agent
/// inherits — see `delegate`), the conversation the spawned jobs belong to, and
/// the nesting depth. Built once by the wiring and threaded through the tools,
/// so the same values aren't repeated (and allowed to drift) at every
/// construction site.
class AgentToolContext {
  final SubAgentScheduler scheduler;
  final AgentPipeline pipeline;
  final String parentReference;
  final PermissionPolicy parentPolicy;
  final String originConversationId;
  final int depth;

  /// The parent agent's resolved system prompt. A spawned sub-agent runs under
  /// this verbatim (plus its own task) — there is no per-sub-agent identity
  /// catalog, so the parent's identity is the single source. Threaded here so
  /// the scheduler builds the sub-agent without re-resolving it.
  final String parentSystemPrompt;

  const AgentToolContext({
    required this.scheduler,
    required this.pipeline,
    required this.parentReference,
    required this.parentPolicy,
    required this.originConversationId,
    required this.depth,
    required this.parentSystemPrompt,
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
/// Returns the built agent for [_run]'s loop. When null (or when the job
/// has no panel host) the old inline build is used and the sub-agent stays
/// telemetry-only. All parameters come from [_run]; see it for semantics.
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

  /// The identity the sub-agent runs under — its parent's resolved system
  /// prompt. Captured at spawn so a later `send` can re-run the channel on the
  /// same identity under the same model/policy/depth.
  final String systemPrompt;
  final ToolProfile toolProfile;

  /// The resolved `"provider/model"` the sub-agent runs under (the delegation's
  /// `llm_provider`/`llm_model` if given, else inherited from the parent).
  final String modelReference;

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
  /// later `send` can continue it. null for channels that never ran a loop
  /// (e.g. provider-build failure).
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
    required this.systemPrompt,
    required this.toolProfile,
    required this.modelReference,
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
  /// null (the default) → [_run] uses the telemetry-only [SubAgentSink],
  /// so the sub-agent streams into its parent's chat as progress lines.
  AgentSink? panelSink;

  /// Panel host built by the persistence hook when this job is live-panelized.
  /// Stored as the abstract [HostInterface] (never the concrete renderer host)
  /// so the agent layer never depends on the terminal UI. When non-null,
  /// [_run] hands this to [subAgentSessionFactory] to build a first-class
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
/// each job gets its own provider (resolved via the registry), a policy derived
/// from its tool profile, its profile's tool set, and an event bus.
class SubAgentScheduler {
  final ProviderRegistry registry;
  final AgentPipeline pipeline;

  /// `[prompts.main]` override forwarded to [resolveMainPrompt] so the entry
  /// agent's identity can be customized without rebuilding the pipeline. A
  /// sub-agent inherits its parent's resolved prompt, so this propagates down.
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

  /// Read-only session (`--safe-mode`): when true, `write`/`edit`/`bash` are
  /// stripped from every profile's registry before the policy is derived, so
  /// the policy tracks the filtered set automatically.
  final bool safeMode;

  /// Set by the wiring to enable nested delegation. Null (default) means
  /// sub-agents can't spawn further sub-agents.
  NestedDelegateToolBuilder? delegateToolBuilder;

  /// Set by the wiring to persist sub-agent transcripts. Null (default) keeps
  /// the historical in-memory-only behavior (job history discarded on exit).
  SubAgentPersistenceFactory? persistence;

  /// Set by the wiring to make a live-panelized sub-agent a first-class
  /// session. [_run] delegates Agent construction + Conversation
  /// registration to it (building the agent with the panel host's asker so a
  /// focused sub-agent panel becomes the active conversation). Null (default) →
  /// old inline, telemetry-only build. Mirrors [NestedDelegateToolBuilder] and
  /// [persistence]: the wiring sets it once at the composition root.
  SubAgentSessionFactory? subAgentSessionFactory;

  /// The app's configured permission policy, threaded in by the wiring so
  /// unattended agents (notably [runStandalone] workflow nodes, which have no
  /// parent conversation) inherit the user's tool decisions — critically the
  /// bash decision, so `--yolo` / `--allow bash:…` can re-enable shell for a
  /// workflow that needs it while bash stays gated (denied) by default. Null →
  /// empty policy (bash gated off).
  PermissionPolicy? basePolicy;

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
  /// running, no history). One in-flight turn per channel.
  String? send(SubAgentJob job, String text) {
    if (_disposed) return 'scheduler disposed';
    if (!job.status.isTerminal) {
      return 'channel ${job.id} is still ${job.status.name}; `read` it first';
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
    unawaited(
        _run(job, text, cancelSignal: job._cancel.future, seedHistory: job.history));
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
  ///
  /// [parentSystemPrompt] is the identity the sub-agent runs under (its
  /// parent's resolved prompt). [toolProfile] picks its tools. [modelReference]
  /// (a `"provider/model"` from the delegation's `llm_provider`/`llm_model`)
  /// overrides the inherited model; null inherits [parentReference].
  SubAgentJob spawn({
    required String task,
    required ToolProfile toolProfile,
    required String parentSystemPrompt,
    required String parentReference,
    required PermissionPolicy parentPolicy,
    required String originConversationId,
    String? modelReference,
    int depth = 0,
    Future<void>? sessionCancelSignal,
    List<Message>? seedHistory,
    String? label,
  }) {
    final id = 'j$_nextId';
    _nextId++;
    final resolvedReference = modelReference ?? parentReference;
    final job = SubAgentJob(
      id: id,
      label: label ?? 'sub-agent',
      systemPrompt: parentSystemPrompt,
      toolProfile: toolProfile,
      modelReference: resolvedReference,
      originConversationId: originConversationId,
      parentReference: parentReference,
      parentPolicy: parentPolicy,
      depth: depth,
      result: Completer<DelegationResult>(),
      bus: AgentEventBus(),
      cancel: Completer<void>(),
    );

    // Enforce the depth cap at the single chokepoint so no spawn path (the
    // delegate tool, a nested sub-agent) can bypass it by passing an
    // un-incremented depth. The nested delegate tool is *also* withheld from a
    // maxed-out agent in [_toolsForProfile], but that's only a UX nicety — this
    // is the real guard. Return a pre-errored job (not tracked in [_jobs]) so
    // callers like `delegate` still resolve cleanly.
    if (!quota.allowsDepth(depth)) {
      job._bus.emit(JobAgentEvent(job.id, job.label,
          NoticeAgentEvent('depth cap', NoticeKind.error)));
      _finish(
          job,
          DelegationResult.error(
              'max nesting depth (${quota.maxDepth}) exceeded'),
          SubAgentJobStatus.errored);
      return job;
    }

    _jobs.add(job);
    _jobSubs[job.id]?.cancel();
    _jobSubs[job.id] = job.eventBus.events.listen(_merged.add);
    if (sessionCancelSignal != null) {
      sessionCancelSignal.whenComplete(job.cancel);
    }

    // Mint a persisted conversation for this job (if persistence is wired) and
    // stash its id + recorder on the job so the transcript can be written at the
    // Detached: must not block returning the job, and a store failure must
    // never fail the spawn. When persistence is wired, kick off _persistJob and
    // only *then* start _run — so the coordinator's persistence hook can mint
    // the conversation, build the live panel, and set [SubAgentJob.panelSink]
    // before the agent streams into it. spawn() itself stays synchronous and
    // returns the job immediately (callers use it before the run starts),
    // matching its pre-panelization contract.
    final run = () => _run(job, task, cancelSignal: job._cancel.future,
        seedHistory: seedHistory);
    if (persistence != null) {
      unawaited(_persistJob(job, originConversationId)
          .then((_) => unawaited(run())));
    } else {
      unawaited(run());
    }
    return job;
  }

  /// Build the `subAgent` meta for [job] and hand it to the persistence factory
  /// to mint a conversation + recorder, which are stashed on [job].
  Future<void> _persistJob(
    SubAgentJob job,
    String originConversationId,
  ) async {
    final factory = persistence;
    if (factory == null) return;
    final reference = job.modelReference;
    final policy = _policyForProfile(job.toolProfile, job.parentPolicy);
    final system = job.systemPrompt;
    // The model ref carries the provider prefix; the stored providerId is just
    // the prefix portion for quick resumption without a registry lookup.
    final providerId = reference.contains('/') ? reference.split('/').first : null;
    final meta = ConversationMetaInput.subAgent(
      model: reference,
      providerId: providerId,
      policy: policy,
      systemPrompt: system,
      targetName: job.label,
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
    String task, {
    required Future<void> cancelSignal,
    List<Message>? seedHistory,
  }) async {
    await quota.acquire();
    try {
      if (job.isCancelled || _disposed) {
        _finish(job, DelegationResult.error('cancelled'),
            SubAgentJobStatus.cancelled);
        return;
      }
      job.status = SubAgentJobStatus.running;
      final DelegationResult result;
      try {
        result = await _runAgent(job, task, cancelSignal, seedHistory);
      } on _ProviderBuildFailure catch (e) {
        _finish(job, DelegationResult.error(e.message),
            SubAgentJobStatus.errored);
        return;
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
      quota.release();
    }
  }

  Future<DelegationResult> _runAgent(
    SubAgentJob job,
    String task,
    Future<void> cancelSignal,
    List<Message>? seedHistory,
  ) async {
    final LlmProvider provider;
    try {
      provider = registry.build(
        job.modelReference,
        maxTokens: maxTokens,
        streamIdleTimeout: streamIdleTimeout,
        requestTimeout: requestTimeout,
      );
    } catch (e) {
      throw _ProviderBuildFailure('failed to build provider: $e');
    }

    // One context for the tools + policy this sub-agent runs with. The policy
    // is derived from its tool profile (plus `delegate` when nesting is wired),
    // so a sub-agent may use exactly what its profile grants — never the
    // parent's allow-list. The sub-agent inherits the parent's identity
    // ([parentSystemPrompt]) via the nested context.
    final ctx = AgentToolContext(
      scheduler: this,
      pipeline: pipeline,
      parentSystemPrompt: job.systemPrompt,
      parentReference: job.modelReference,
      parentPolicy: _policyForProfile(job.toolProfile, job.parentPolicy),
      originConversationId: job.originConversationId,
      depth: job.depth,
    );
    final tools = _toolsForProfile(job.toolProfile, ctx, job.depth);
    // A panelized job has its sink supplied by the coordinator (a BusSink over
    // the panel's host); otherwise fall back to the telemetry-only SubAgentSink
    // that streams progress into the parent's chat.
    final sink = job.panelSink ??
        SubAgentSink(jobId: job.id, label: job.label, bus: job.eventBus);

    final system = job.systemPrompt;
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
            maxSteps: defaultMaxSteps,
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
            maxSteps: defaultMaxSteps,
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

    // Extract the result BEFORE any abort message is appended, so an aborted
    // job's synthetic message can't masquerade as a real answer.
    final result = _extractResult(job.label, history);

    // Persist the complete transcript to the job's conversation (if it has one).
    // Completion-time persistence is enough; mid-turn incremental writes are a
    // follow-up. Best-effort: a write failure must not fail the job. `replace`
    // rewrites the whole file atomically, so a `send`/re-run that rewrites the
    // grown history stays consistent. An aborted turn (budget trip, provider
    // error, …) appends its reason so a restored sub-agent panel shows why it
    // stopped — the live notice is display-only.
    final recorder = job._recorder;
    if (recorder != null) {
      final aborted = agent.abortedReason;
      if (aborted != null) {
        history.add(Message(
          role: Role.assistant,
          content: [TextBlock('[turn aborted: $aborted]')],
        ));
      }
      try {
        await recorder.replace(history);
      } catch (_) {
        // Ignore: the in-memory result still returns to the orchestrator.
      }
    }

    return result;
  }

  /// Run a single agent turn for a codergen node with [systemPrompt] as the
  /// agent's identity and [task] as the user message, returning the agent's
  /// final answer text. This is the public seam for the attractor pipeline's
  /// `CodergenBackend`: a node carries its own `system_prompt` + `llm_model`/
  /// `llm_provider` (tin-80ll), so this builds the agent from those instead of
  /// a catalog identity. It reuses the scheduler's model resolution and
  /// system-prompt assembly — without a [SubAgentJob], quota, or panel/session.
  ///
  /// Depth is 0 (a top-level pipeline node). [sink] streams the turn's text
  /// (e.g. into the conversation host); [cancelSignal] aborts it. [seedHistory]
  /// is reserved for the `full`-fidelity phase.
  ///
  /// [modelReference] is the node's resolved `"provider/model"` (from
  /// `llm_model`/`llm_provider`); when null, [parentReference] (the
  /// conversation's resolved model) is used. [toolProfile] selects the agent's
  /// tool set (default `full`); [includeDelegate] adds the nested `delegate`
  /// tool when nesting is wired — set both for a read-only, non-spawning
  /// one-shot agent (e.g. a region query).
  ///
  /// **Gated writes.** [gateWrites] (used by the workflow path) stops
  /// `write`/`edit` from being pre-approved: they fall back to the policy's
  /// decision (`ask` normally, `allow` under `--yolo`/`--allow`) and reach
  /// [asker] when they ask. [policy] is an explicit policy instance used for
  /// the agent as-is (widened in place with the profile's tools): pass the
  /// SAME instance for a whole run so an "always allow" answer the asker
  /// remembers persists across nodes. Defaults (no asker, no gating) preserve
  /// the historical auto-allow behavior for existing callers.
  Future<RunAgentResult> runStandalone({
    required String systemPrompt,
    required String task,
    String parentReference = '',
    String? modelReference,
    List<Message>? seedHistory,
    Future<void>? cancelSignal,
    required AgentSink sink,
    ToolProfile toolProfile = ToolProfile.full,
    bool includeDelegate = true,
    PermissionPolicy? parentPolicy,
    bool gateWrites = false,
    PermissionPolicy? policy,
    PermissionAsker? asker,
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
      return RunAgentResult.error('failed to build provider: $e',
          transient: true);
    }

    // A node agent runs with the selected tool profile plus `delegate` (when
    // nesting is wired and [includeDelegate] is set), so it can work directly
    // AND reach further sub-agents. Identity comes from [systemPrompt]; the
    // model from [reference].
    final base = _effectiveProfileTools(toolProfile).toList();
    final PermissionPolicy effectivePolicy;
    if (policy != null) {
      // Caller-owned instance (shared across a whole run): widen it in place
      // so remembered session rules survive past this node.
      _widenPolicyInPlace(policy, toolProfile, gateWrites: gateWrites);
      effectivePolicy = policy;
    } else {
      effectivePolicy = _policyForProfile(
          toolProfile, parentPolicy ?? basePolicy ?? PermissionPolicy(),
          gateWrites: gateWrites);
    }
    final tools = <Tool>[...base];
    final system = resolveIdentityPrompt(systemPrompt,
        safeMode: safeMode, loadProjectContext: pipeline.loadProjectContext);
    if (includeDelegate && delegateToolBuilder != null) {
      final nestedCtx = AgentToolContext(
        scheduler: this,
        pipeline: pipeline,
        parentSystemPrompt: system,
        parentReference: reference,
        parentPolicy: effectivePolicy,
        originConversationId: '',
        depth: 1,
      );
      tools.add(delegateToolBuilder!(nestedCtx));
    }

    final agent = Agent(
      provider: provider,
      tools: ToolRegistry(tools),
      sink: sink,
      policy: effectivePolicy,
      asker: asker ?? _autoDenyAsker,
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
    if (extracted.isError) {
      return RunAgentResult.error(extracted.content,
          // A provider failure (rate limit, dropped stream) may clear on a
          // retry; budget/steps exhaustions and everything else will not.
          transient: agent.abortedKind == AbortedKind.provider);
    }
    return RunAgentResult(extracted.content);
  }

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

  /// The profile's tool set, minus the safe-mode-disabled tools when
  /// `--safe-mode` is on. The single source of truth for both the registry and
  /// the derived policy, so the two never drift.
  Iterable<Tool> _effectiveProfileTools(ToolProfile profile) {
    final tools = toolSetFor(profile);
    return safeMode ? stripForSafeMode(tools) : tools;
  }

  /// Build the profile's tool set directly, and add a nested `delegate` tool
  /// when nesting is allowed. No base set to filter — each profile brings its
  /// own tools.
  ToolRegistry _toolsForProfile(
      ToolProfile profile, AgentToolContext ctx, int depth) {
    final tools = [..._effectiveProfileTools(profile)];
    if (depth < quota.maxDepth && delegateToolBuilder != null) {
      final nestedCtx = AgentToolContext(
        scheduler: this,
        pipeline: pipeline,
        // A nested sub-agent inherits this sub-agent's identity (which itself
        // inherited the parent's) — identity flows down unchanged.
        parentSystemPrompt: ctx.parentSystemPrompt,
        parentReference: ctx.parentReference,
        parentPolicy: ctx.parentPolicy,
        originConversationId: ctx.originConversationId,
        depth: depth + 1,
      );
      tools.add(delegateToolBuilder!(nestedCtx));
    }
    return ToolRegistry(tools);
  }

  /// Derive a sub-agent's policy from its tool profile: it may use exactly its
  /// profile's tools plus `delegate` when nesting is wired. Anything else is
  /// absent from the policy → `ask` (the unmapped-tool default) → denied by the
  /// auto-deny asker. The parent's static permission rules carry forward.
  ///
  /// **bash is deliberately NOT auto-allowed.** `write`/`edit` are confined by
  /// `SandboxedFileSystem` and backed up, so they're safe to pre-approve; bash
  /// is the uncontained destructive vector, so it inherits the *parent's* bash
  /// decision (`ask` normally → a prompt under an interactive asker, a deny
  /// under the auto-deny asker; `allow` under `--yolo` or an explicit `--allow
  /// bash:…`). The parent's `defaults` are spread in first so this inheritance
  /// holds even when the parent expresses bash via a default (e.g. `--yolo`)
  /// rather than a static rule.
  PermissionPolicy _policyForProfile(
          ToolProfile profile, PermissionPolicy parent,
          {bool gateWrites = false}) =>
      PermissionPolicy(
        defaults: {
          ...parent.defaults,
          for (final t in _effectiveProfileTools(profile))
            if (t.schema.name != 'bash' &&
                // Gated path (e.g. workflow nodes with their own asker):
                // write/edit prompt per call like the main agent instead of
                // being pre-approved; they inherit the parent's decision
                // (allow under --yolo, ask otherwise).
                !(gateWrites &&
                    (t.schema.name == 'write' || t.schema.name == 'edit')))
              t.schema.name: PermissionDecision.allow,
          if (delegateToolBuilder != null) 'delegate': PermissionDecision.allow,
        },
        rules: parent.staticRules,
      );

  /// Widen [policy] in place with the profile's tool set — the caller keeps
  /// the same instance for a whole run, so session rules the asker remembers
  /// ("always allow") persist across every node that shares it. Idempotent;
  /// respects [gateWrites] exactly like [_policyForProfile].
  void _widenPolicyInPlace(PermissionPolicy policy, ToolProfile profile,
      {required bool gateWrites}) {
    for (final t in _effectiveProfileTools(profile)) {
      final name = t.schema.name;
      if (name == 'bash') continue; // never auto-allow bash
      if (gateWrites && (name == 'write' || name == 'edit')) continue;
      policy.defaults[name] = PermissionDecision.allow;
    }
    if (delegateToolBuilder != null) {
      policy.defaults['delegate'] = PermissionDecision.allow;
    }
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

/// Internal signal that provider construction failed — surfaced as a clean
/// [DelegationResult.error] rather than a stack trace.
class _ProviderBuildFailure {
  final String message;
  const _ProviderBuildFailure(this.message);
}
