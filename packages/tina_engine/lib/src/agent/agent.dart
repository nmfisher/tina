import 'dart:async';

import 'package:logging/logging.dart';

import '../llm/http.dart' show isTransportRetryable;
import '../llm/message.dart';
import '../llm/provider.dart';
import '../permissions/policy.dart';
import '../permissions/prompt.dart';
import '../tools/tool.dart';
import 'run_lifecycle.dart';
import 'agent_sink.dart';
import 'pause_gate.dart';
import 'stream_consumer.dart';
import 'token_budget.dart';
import 'tool_executor.dart';
import 'tool_executor.dart' as tool_executor;
import 'tool_guards.dart';
import 'tool_hooks.dart';

final _log = Logger('tina.agent');

/// Hard-coded ceiling on tool invocations per turn. The run loop bounds *steps*
/// via [Agent.maxSteps] but not *tool uses* — this is the coarse backstop that
/// complements the token spend-funnel (~10× maxSteps=500, so legitimate
/// multi-file refactors have headroom; tool uses are serial per step). When
/// tripped the turn stops with a notice. `--yolo` can't extend it (it only
/// relaxes the ask-gate). No config surface by design.
const int kMaxToolCallsPerRun = 5000;

/// tin-cmpt: the per-turn spend (measured + estimated, in tokens) past which a
/// turn that has touched NO mutable tool gets one advisory — an in-band user
/// message the model reads plus a stderr notice the operator reads — saying
/// the turn has produced no checkpoint. Absolute, not a fraction of a cap:
/// its whole point is to still exist when the cap is gone
/// (`--max-turn-tokens 0`). Generous by design — long but productive turns
/// (big greps, big reads) must not be nagged. No config surface by design.
const int kNoCheckpointAdvisorySpend = 300000;

/// tin-cmpt: the in-band text injected when a long turn has no checkpoint.
/// Exported so tests assert the exact seam, like the budget messages do.
const String kNoCheckpointAdvisoryLine = '[checkpoint] this turn has run long '
    'without editing a file or making a commit, so nothing on disk records '
    'its work — if the turn aborts, it all unwinds. Land a checkpoint: make '
    'the smallest useful edit or commit now, or say what you have and stop.';

/// tin-cmpt: the mutable-tool names that count as a checkpoint touch. `edit`,
/// `write` and `bash` (a commit goes through bash; every other mutating path
/// in this engine is one of the first two). Everything else — read, glob,
/// grep, search, ls, stat, which, git, fetch, web_search, delegate — is
/// observation and leaves no trace by itself.
const Set<String> kCheckpointTouchTools = {'edit', 'write', 'bash'};

/// Turn-level transport retry ladder (#28) — first backoff. Generous by
/// design: these errors land MID-stream, after a provider that was already
/// answering hiccuped, so a sub-second retry (the transport ladder's 250ms)
/// would hammer a wounded upstream. 15s doubling to [maxTransportBackoff].
const firstTransportBackoff = Duration(seconds: 15);

/// Ceiling on ONE agent-level transport backoff — a server `retryAfter` hint
/// is honored up to this and the exponential ladder tops out here, so a
/// misconfigured upstream can't park a headless run for hours per attempt.
const maxTransportBackoff = Duration(seconds: 120);

/// The backoff before ladder attempt [attempt] (1-based: the delay before the
/// FIRST retry). The error's `retryAfter` overrides this when the server
/// supplied one — capped at [maxTransportBackoff] like the hint itself.
Duration transportBackoffFor(int attempt, {Duration? retryAfter}) {
  if (retryAfter != null) {
    return retryAfter > maxTransportBackoff ? maxTransportBackoff : retryAfter;
  }
  var d = firstTransportBackoff;
  for (var i = 1; i < attempt; i++) {
    d *= 2;
    if (d >= maxTransportBackoff) return maxTransportBackoff;
  }
  return d;
}

/// How many of the most recent agent-loop STEPS keep their tool results at
/// full size (#44). A result older than this window is dead weight at full
/// size — the model metabolized it when it arrived (extracting what mattered
/// into its own prose) but every later request re-sends it verbatim: #42
/// measured ONE 53KB read costing ~585K cumulative tokens across a 45-step
/// turn. Why 8: deep enough that any follow-up work on a fresh result happens
/// inside the window; shallow enough that a long turn's steady-state context
/// stays bounded to recent output plus prose. Tunable like
/// [kToolResultStubThreshold]; both must be exceeded for a stub.
const int kToolResultRetentionSteps = 8;

/// Minimum serialized size (bytes) of a tool_result body worth stubbing
/// (#44). Small results are cheap context and often load-bearing (error
/// text, exit codes, short paths) — only bodies larger than this are aged
/// out. Bytes = the serialized length the token estimator counts, so the
/// threshold is directly comparable to the request-size arithmetic.
const int kToolResultStubThreshold = 4096;

/// Replace AGED LARGE tool_result blocks in [history] with short stubs
/// (#44), in place. A block qualifies when its serialized body exceeds
/// [kToolResultStubThreshold] bytes AND it was produced more than
/// [kToolResultRetentionSteps] steps before [currentStep] — the current
/// step's results and everything inside the retention window are never
/// touched, nor are small results. The stub keeps the block's `tool_use_id`
/// and message structure intact so tool_use/tool_result pairing is NEVER
/// severed (providers reject an unpaired use — the hard invariant); only
/// the content string shrinks. Returns how many blocks were stubbed
/// (0 = no-op: all-small or all-recent history).
///
/// Runs between steps, BEFORE any compaction pass at the same checkpoint:
/// it is cheap, deterministic, and LLM-free, so it composes with
/// compaction — stubbing bounds the steady-state context, compaction
/// rescues the rest. Silent by design: the UI already showed the content
/// live when the tool completed; there is nothing new to announce.
///
/// "Step" here means the agent-loop index: the turn's opening user message
/// carries no results, and each step appends exactly ONE user
/// (tool_result) batch — possibly with several blocks — so the Nth
/// tool-result batch in history order was produced by loop step N (1-based).
/// Age = currentStep − that batch number; a batch is aged only when the age
/// EXCEEDS the retention window (blocks in a batch age together). The stub
/// names the tool by looking its `tool_use_id` up in the history's
/// tool_use blocks (defensive fallback if the use was summarized away).
int stubAgedToolResults(List<Message> history, {required int currentStep}) {
  // id → tool name, from every tool_use block in history (the assistant
  // message each result batch answers). One cheap pre-pass; the pairing
  // itself is never modified — only the result body is.
  final useNames = <String, String>{};
  for (final m in history) {
    if (m.role != Role.assistant) continue;
    for (final b in m.content) {
      if (b is ToolUseBlock) useNames[b.id] = b.name;
    }
  }

  var stubbed = 0;
  var batchNumber = 0;
  for (final m in history) {
    if (m.role != Role.user) continue;
    final hasResult = m.content.any((b) => b is ToolResultBlock);
    if (!hasResult) continue;
    batchNumber++;
    final ageSteps = currentStep - batchNumber;
    if (ageSteps <= kToolResultRetentionSteps) continue;
    for (var b = 0; b < m.content.length; b++) {
      final block = m.content[b];
      if (block is! ToolResultBlock) continue;
      if (block.content.length <= kToolResultStubThreshold) continue;
      final originalBytes = block.content.length;
      final toolName = useNames[block.toolUseId] ?? 'unknown tool';
      m.content[b] = ToolResultBlock(
        toolUseId: block.toolUseId,
        isError: block.isError,
        content: '[elided after $ageSteps steps: $toolName result, '
            '$originalBytes bytes — re-run to recover]',
      );
      stubbed++;
    }
  }
  return stubbed;
}

/// Why a turn stopped abnormally, classified by cause. Callers that decide
/// whether to retry (e.g. the pipeline's codergen nodes) treat [provider] and
/// [transport] failures as transient — a rate limit or dropped stream may
/// clear on its own — while [budget]/[steps] exhaustions and [cancel] never
/// will. The split between [provider] and [transport]: a [transport] failure
/// was transport-retryable and the agent's OWN retry ladder (#28) exhausted
/// its attempts, so the retry decision is already spent; a [provider] failure
/// is everything else that may still clear (auth, rate-limit-forever, empty
/// completions, cut streams). [providerTerminal] means the provider supplied
/// a terminal account error or completion reason, such as output exhaustion
/// or filtering;
/// resending the unchanged request is not an appropriate recovery.
enum AbortedKind {
  none,
  provider,
  transport,
  budget,
  steps,
  cancel,
  providerTerminal,
}

const _compactSystemPrompt = '''
You are summarizing a coding-assistant conversation for context
preservation. Output ONLY the summary — no preamble, no closing.
Use terse markdown bullets, <= 400 words. Preserve:
- file paths the user or assistant referenced or edited
- decisions taken and the reason behind them
- unresolved questions or pending work
- errors encountered and how they were resolved
Omit pleasantries and reasoning that did not lead anywhere.
''';

/// Fired (and awaited) by [Agent] after a message is appended to the live
/// history — the turn's user message, each assistant completion, each
/// tool-result batch. Write-through persistence (#25): the app wires this to
/// the [SessionRecorder] so a mid-turn kill leaves completed exchanges on
/// disk. Null (the default) = nothing fires and the turn is byte-identical to
/// the pre-observer behavior. A throw is caught, logged, and swallowed.
typedef HistoryAppendObserver = Future<void> Function(Message);

/// Fired (and awaited) ONCE after [Agent.compact] rewrites the history in
/// place, with the FINAL post-compact list — a REWRITE, not appends. Null (the
/// default) = nothing fires. A throw is caught, logged, and swallowed.
typedef HistoryReplaceObserver = Future<void> Function(List<Message>);

class Agent {
  LlmProvider _provider;

  /// The provider this agent sends requests to. Mutable so `/model` can swap
  /// the provider instance at runtime — the agent re-reads it on each [run].
  LlmProvider get provider => _provider;
  set provider(LlmProvider value) => _provider = value;
  final ToolRegistry tools;
  PermissionMode? _announcedMode;
  Message? _modeNotice;
  final AgentSink sink;
  final PermissionPolicy policy;
  final PermissionAsker asker;
  final int maxSteps;

  /// Per-turn / per-session token caps. An immutable value: each
  /// `record` / `resetTurn` / `resetSession` returns a new [TokenBudget] and
  /// we reassign this field to it. So read live totals through `budget` here,
  /// not a reference captured before the turn (a captured one goes stale).
  TokenBudget? budget;

  /// When set, a per-session budget trip pauses ALL agents and asks the user
  /// (continue/abort) instead of hard-aborting the turn. Null in headless /
  /// tests that want the legacy abort behavior.
  final PauseGate? pauseGate;

  /// Mid-turn auto-compact: when the NEXT request's estimated input tokens
  /// exceed this, the older history is summarized in place (keeping the
  /// trailing [autoCompactKeepMessages] messages verbatim) before the request
  /// goes out. 0 (the engine default) disables it — the app wires the user's
  /// `--auto-compact-threshold` here so every long autonomous turn (headless
  /// `--prompt`, workflow nodes, a chatty interactive session) is bounded by
  /// compaction rather than dying at the per-turn token ceiling. Mutable so a
  /// runtime adjustment (the `/auto-compact` command) applies without a
  /// rebuild, matching the app-level threshold's contract.
  int autoCompactThreshold;

  /// How many trailing messages a mid-turn auto-compact keeps uncompressed.
  /// The split lands on an assistant-message boundary so a tool_use and its
  /// tool_result are never severed (see [compact]).
  int autoCompactKeepMessages;

  /// Optional post-success gate on a tool result, run by the agent AFTER a
  /// tool completes without error and BEFORE its result is appended to the
  /// history the model reads next step. Given the tool name and input, return
  /// a short remediation string (or null for "nothing to add"); a non-null
  /// return is appended to the tool's own content (tool content first, then a
  /// newline, then the verifier text) so the model sees the diagnosis while
  /// its own edit is still in context. The intended headless use is a
  /// post-edit `dart analyze` gate (#22a): a non-compiling edit is fed
  /// straight back so the model can self-correct instead of leaving a scar
  /// that kills the NEXT `dart run` at exit 254. Never fires on error results
  /// (parse-error / unknown-tool / denied / thrown paths skip it), and a
  /// verifier that itself throws is logged and ignored — the tool's own
  /// content ships unchanged. Null (the default) = no verification at all.
  final ToolResultVerifier? resultVerifier;

  /// Write-through seam (#25): fired and AWAITED after every message is
  /// appended to [history] — the turn's user message, each assistant
  /// completion, each tool-result batch. Awaiting keeps the ordering
  /// guarantee a fire-and-forget write cannot: when [run] returns, every
  /// observer for this turn has finished (or failed and been logged), so
  /// teardown can close the store without racing the last write. A throw is
  /// caught, logged, and swallowed — a broken observer degrades to "not
  /// persisted", never aborts the turn. Null (the default) = nothing fires
  /// and behavior is byte-identical to the pre-observer agent.
  HistoryAppendObserver? onHistoryAppend;

  /// Write-through seam for compaction: fired and AWAITED exactly once after
  /// [compact] rewrites [history] (clear + rebuild), with the FINAL
  /// post-compact list — a REWRITE, not appends. Receives the live [history]
  /// list itself; observers that persist must treat it as read-only (compact
  /// continues mutating the same list afterwards). Null (the default) =
  /// nothing fires. Same throw-containment as [onHistoryAppend].
  HistoryReplaceObserver? onHistoryReplace;

  /// Resolved once at construction; reused for every provider call so the
  /// system prefix stays stable across a multi-step turn (cache-friendly).
  final String system;

  /// Turn-level transport retry ladder (#28): how many EXTRA times a step
  /// re-sends when the provider stream fails MID-stream with a
  /// transport-retryable error ([isTransportRetryable] — the same predicate
  /// the policy-layer [RetryingProvider] uses, which only covers failures
  /// before any content). Each re-send is a fresh real send — metering books
  /// per-attempt spend inside the provider stack, nothing is re-booked here.
  ///
  /// 0 (the default) preserves the pre-#28 behavior exactly: the first
  /// mid-stream retryable error aborts the turn. The headless runner passes
  /// 5; the TUI does not (yet) opt in.
  final int transportRetryAttempts;

  /// Wall-clock between ladder attempts: [Duration.zero] default is replaced
  /// by the real schedule — the error's `retryAfter` (capped at
  /// [maxTransportBackoff]) when the server supplied one, else exponential
  /// 15s → 30s → 60s → 120s. Injectable ONLY so tests don't sleep; the
  /// function still receives the computed duration so tests can assert it.
  final Future<void> Function(Duration delay)? transportBackoffDelay;

  /// Retry empty provider responses without advancing a tool step or changing
  /// the request history. Three retries wait 1, 2, then 4 seconds by default.
  final int emptyCompletionRetryAttempts;
  final Future<void> Function(Duration delay)? emptyCompletionBackoffDelay;

  /// Extra deny-preserving guards ([ToolGuard]) for this agent's tool calls.
  /// The [ToolExecutor] always runs the mandatory policy and phase guards
  /// first ([PolicyToolGuard], [RegistryPhaseGuard]); these are appended
  /// after them in the ordered, denial-combining chain
  /// ([combineGuardBlocks]) — checked at the same three gates, never able to
  /// override an earlier guard's rejection, and a throwing guard fails
  /// closed. Empty (the default) = behavior unchanged.
  final List<ToolGuard> executionGuards;

  /// AROUND-execution hooks ([ToolExecutionHook]) wrapping each tool's
  /// execute call (first hook outermost), after the guards. Empty (the
  /// default) = behavior unchanged.
  final List<ToolExecutionHook> executionHooks;

  /// POST-tool hooks ([ToolResultHook]) running after the legacy verifier
  /// on successful results: first non-null verdict is appended to the tool
  /// content, a throwing hook is skipped. Empty (the default) = behavior
  /// unchanged.
  final List<ToolResultHook> resultHooks;

  /// Observation-only hooks ([ToolObserver]) notified additively at the
  /// toolStart / toolOutput / toolComplete points; an observer exception is
  /// contained and can never change execution. Empty (the default) =
  /// behavior unchanged.
  final List<ToolObserver> toolObservers;

  Agent({
    required LlmProvider provider,
    required this.tools,
    required this.sink,
    required this.policy,
    required this.asker,
    this.maxSteps = 500,
    this.budget,
    this.pauseGate,
    this.autoCompactThreshold = 0,
    this.autoCompactKeepMessages = 6,
    this.resultVerifier,
    this.onHistoryAppend,
    this.onHistoryReplace,
    this.transportRetryAttempts = 0,
    this.transportBackoffDelay,
    this.emptyCompletionRetryAttempts = 3,
    this.emptyCompletionBackoffDelay,
    this.executionGuards = const [],
    this.executionHooks = const [],
    this.resultHooks = const [],
    this.toolObservers = const [],
    required this.system,
  }) : _provider = provider;

  /// Await [onHistoryAppend] for [m], swallowing observer failures — a broken
  /// recorder must degrade to "not persisted", never abort the turn. The
  /// await is what makes the seam safe to tear down behind: when [run]
  /// returns, no observer write for this turn is still in flight.
  ///
  /// NOT async, and deliberately returns null (never an already-completed
  /// future) when no observer is installed: `await` on anything — even a
  /// synchronously-completed future — suspends the turn loop for a microtask,
  /// and "null = byte-identical behavior" must hold all the way down to
  /// suspension timing (a queued microtask ran between the user message and
  /// the provider subscription and hung a gate-based test fixture; production
  /// timing shifts just as invisibly). Call sites skip the await on null.
  Future<void>? _notifyAppend(Message m) {
    final cb = onHistoryAppend;
    if (cb == null) return null;
    return _guardObserver(() => cb(m));
  }

  /// Await [onHistoryReplace] with the post-compact [messages], containing
  /// observer failures the same way [onHistoryAppend] is — and returning null
  /// (zero suspensions) when no observer is set, for the same reason.
  Future<void>? _notifyReplace(List<Message> messages) {
    final cb = onHistoryReplace;
    if (cb == null) return null;
    return _guardObserver(() => cb(messages));
  }

  Future<void> _guardObserver(Future<void> Function() run) async {
    try {
      await run();
    } catch (e, st) {
      _log.warning('history observer failed', e, st);
    }
  }

  /// Run one user turn. The agent may issue several provider calls if tools
  /// are invoked. [cancelSignal], when completed, aborts the current
  /// in-flight stream and exits the turn cleanly.
  /// Why the previous turn stopped, when it stopped abnormally — a budget
  /// trip, a provider/API error (remote rate limit, insufficient funds, auth),
  /// a cut-off stream, the action cap, or max steps. null after a normal
  /// finish (or a cancel). Reset at the top of every [run]. The interactive
  /// controller persists this as a synthetic assistant message so a restored
  /// session still shows why the turn died; it is never appended to history
  /// here, so the scheduler's result extraction can't mistake it for a real
  /// answer.
  String? abortedReason;

  /// The same stop classified by cause, for callers deciding whether a retry
  /// could succeed: [AbortedKind.provider] and [AbortedKind.transport]
  /// failures (rate limit, dropped stream, transient build failure) may clear
  /// on their own; terminal provider responses, budget/steps exhaustions and
  /// cancellations will not.
  /// [AbortedKind.transport] means the failure was transport-retryable and
  /// the agent's own turn-level ladder (#28) ALREADY exhausted its attempts —
  /// the built-in retry is spent, unlike [AbortedKind.provider] which no
  /// retry has touched. Reset alongside [abortedReason].
  AbortedKind abortedKind = AbortedKind.none;

  /// Whether the 90% per-turn budget SOFT margin (#37) has fired in the
  /// CURRENT turn — i.e. the one-time "finish up and write your closing
  /// summary" message has been injected into the turn's history. The agent
  /// sets it exactly once per turn (see the check after
  /// [TokenBudget.record]) and resets it at the top of every [_runTurn], so
  /// a new turn gets its own nudge. Exposed so regression tests can assert
  /// the once-per-turn semantics.
  bool get softMarginFired => _softMarginFired;
  bool _softMarginFired = false;

  /// Once-per-turn latch (#43) for the 50% cumulative-spend compaction
  /// trigger. When [budget!.turnSpendCompactTrigger()] first reaches true,
  /// the agent runs [compact] once for the turn, then sets this so the
  /// trigger does not re-fire (repeating compaction buys nothing and would
  /// waste provider calls). Reset each turn with [_softMarginFired]. The
  /// ladder is 50% compact → 90% soft nudge → 100% hard abort.
  bool get turnSpendCompactFired => _turnSpendCompactFired;
  bool _turnSpendCompactFired = false;

  /// tin-cmpt: whether the CURRENT turn has touched a mutable tool —
  /// [kCheckpointTouchTools] — i.e. produced anything that survives the turn.
  /// Set in the tool-result block next to [kMaxToolCallsPerRun]; reset each
  /// turn beside the latches above. Exposed so tests can drive the advisory
  /// without replaying real tool calls.
  bool turnTouchedCheckpoint = false;

  /// tin-cmpt: once-per-turn latch for the no-checkpoint advisory. The
  /// advisory is a nudge, not a wall — one reminder per turn is enough, and
  /// re-firing every step would bury the transcript. Reset each turn with
  /// the other per-turn state. Exposed so regression tests can assert the
  /// once-per-turn semantics, like [softMarginFired].
  bool get checkpointAdvisoryFired => _checkpointAdvisoryFired;
  bool _checkpointAdvisoryFired = false;

  /// Run one user turn. The agent may issue several provider calls if tools
  /// are invoked. [cancelSignal], when completed, aborts the current
  /// in-flight stream and exits the turn cleanly.
  ///
  /// [toolInterruptSignal] is the operator's escape hatch (#31), distinct
  /// from [cancelSignal]: completing it interrupts the turn WITHOUT
  /// cancelling it. The interrupt is only observed around tool execution —
  /// provider stream phases are never torn down mid-token. The tool batch
  /// that is in flight when the signal fires still completes whole (every
  /// tool_use gets its tool_result, appended to history in order), then the
  /// turn ends cleanly: this method returns normally, with no `[cancelled]`
  /// notice, no abort, and `abortedKind == AbortedKind.none`. The next
  /// provider step is never taken. Null (the default) means the feature is
  /// absent and behavior is unchanged.
  ///
  /// The signal is per-run: a caller that runs several turns must hand each
  /// run its own fresh [Future] (e.g. `perTurnInterrupt.future`), never a
  /// future from an earlier turn — a stale completed future would interrupt
  /// the new turn's first tool batch immediately.
  ///
  /// Each run emits identity-based lifecycle signals to sinks that opt in.
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
  }) async {
    final activity = RunActivity(sink);
    try {
      await _runTurn(
        history: history,
        userInput: userInput,
        cancelSignal: cancelSignal,
        toolInterruptSignal: toolInterruptSignal,
        turnTools: turnTools,
      );
    } finally {
      activity.complete();
    }
  }

  Future<void> _runTurn({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
  }) async {
    abortedReason = null;
    abortedKind = AbortedKind.none;
    // The soft margin re-arms every turn: a new user turn gets its own one
    // nudge (the previous turn's spend is zeroed by resetTurn below).
    _softMarginFired = false;
    // Same for the 50%-spend compaction latch (#43): the previous turn's
    // compaction must not suppress this turn's.
    _turnSpendCompactFired = false;
    // tin-cmpt: the no-checkpoint advisory is per-turn like the compaction
    // latch, and the checkpoint-touch ledger starts every turn clean — a
    // turn that edits nothing is exactly the state the advisory exists for.
    _checkpointAdvisoryFired = false;
    turnTouchedCheckpoint = false;
    final userMessage =
        Message(role: Role.user, content: [TextBlock(userInput)]);
    history.add(userMessage);
    final pendingUser = _notifyAppend(userMessage);
    if (pendingUser != null) await pendingUser;

    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);

    // Operator interrupt (#31), distinct from cancel: fires the turn-stop
    // AROUND TOOL EXECUTION only — never mid-stream. Armed eagerly so an
    // interrupt that lands before (or between) tool batches is already
    // pending when the next batch starts (it then begins
    // already-interrupted: the batch's first call ships the prefix line and
    // the remainder stubs, and the turn ends). See the tool-execution block
    // below for the full mechanics.
    final executorState = ToolCallState();
    toolInterruptSignal?.then((_) => executorState.toolInterrupted = true);
    // The per-call dispatch state and its executor: what used to be
    // _runTurn locals (denial counter #27, anomaly streaks #29,
    // sandbox-retry bookkeeping) moved verbatim into [ToolCallState]
    // (tool_executor.dart) and now lives here — created and discarded with
    // the turn, so no streak or retry memory ever survives into the next
    // user turn. The executor is built once per turn and dispatches each
    // call of every batch. The either-signal stop future from main is
    // forwarded so tools stop for cancellation OR operator interrupt
    // (choosing the interrupt alone would mask ordinary cancellation when
    // the interactive host supplies both).
    final toolStopSignal = cancelSignal == null
        ? toolInterruptSignal
        : toolInterruptSignal == null
            ? cancelSignal
            : Future.any<void>([cancelSignal, toolInterruptSignal]);
    final toolExecutor = ToolExecutor(
      policy: policy,
      asker: asker,
      sink: sink,
      state: executorState,
      resultVerifier: resultVerifier,
      cancelSignal: cancelSignal,
      toolInterruptSignal: toolInterruptSignal,
      toolStopSignal: toolStopSignal,
      executionGuards: executionGuards,
      executionHooks: executionHooks,
      resultHooks: resultHooks,
      observers: toolObservers,
    );

    // Action cap: count tool invocations across all steps of this turn. A step
    // may issue many tool calls; this coarse backstop (complementing the token
    // funnel + maxSteps) bounds the total so a runaway loop can't run forever.
    // --yolo can't extend it. Tripping stops the turn with a notice.
    var toolCalls = 0;

    // Step of the last mid-turn auto-compact ATTEMPT. A compaction that fails
    // to shrink the estimate (summary error, nothing safely splittable) must
    // not be retried every step — one attempt per 3 steps bounds the waste.
    var lastCompactAttempt = -3;

    // Consecutive completions that carried NO blocks at all (see the check
    // before the history append below). One retry, then abort.
    var emptyCompletions = 0;

    // Soft margin (#37): the once-per-turn latch is the instance field
    // [_softMarginFired]; it resets here, at the top of every turn, so each
    // new turn gets exactly one nudge (a threshold re-fire would re-nag the
    // model on every step once spend stays past 90%).

    for (var step = 0; step < maxSteps; step++) {
      // Snapshot phase authorization for this step while keeping the catalog
      // stable. A transition cannot authorize execution in the same batch.
      final stepTools = (turnTools ?? tools).forStep();
      // Cancellation, clear, or compaction can remove an earlier notice.
      if (_modeNotice != null && !history.contains(_modeNotice)) {
        _announcedMode = null;
      }
      if (_announcedMode == null &&
          _modeNotice == null &&
          policy.mode == PermissionMode.ask) {
        _announcedMode = policy.mode;
      }
      if (_announcedMode != policy.mode) {
        // Append only: neither the system prompt nor the existing history or
        // tool schemas change when the user switches mode.
        final mode = policy.mode;
        final notice = Message(role: Role.user, content: [
          TextBlock('Runtime permission mode: ${mode.label}. '
              '${mode == PermissionMode.readAll ? 'Read-only: shell, writes, and full-access delegation are disabled. Use dedicated inspection tools.' : 'Actions follow the current permission policy.'}')
        ]);
        history.add(notice);
        final pending = _notifyAppend(notice);
        if (pending != null) await pending;
        _announcedMode = mode;
        _modeNotice = notice;
      }
      if (cancelled) {
        sink.notice('\n[cancelled]\n', kind: NoticeKind.warning);
        abortedKind = AbortedKind.cancel;
        return;
      }

      // Mid-turn auto-compact: tool results accumulate in history faster than
      // any between-turns pass can trim them, so a long autonomous turn (a
      // headless --prompt task, a workflow node) re-sends an ever-growing
      // payload until it drowns in its own context — the per-turn budget then
      // kills a run that was making progress. Two triggers fire a compaction:
      // the next request's estimated input crossing the threshold (a single
      // request too big), or the turn's CUMULATIVE spend (input+output of
      // every round trip) crossing half the per-turn cap — or, when there is
      // NO per-turn cap (tin-cmpt: `--max-turn-tokens 0`), an absolute
      // baseline of half the threshold itself — while the estimate is above
      // half the threshold: the many-steps-on-a-mid-size-context case (65K ×
      // 15 ≈ 1M) where no single request ever grows large enough, but the
      // spend keeps climbing (#42 measured exactly this shape: 45 steps ×
      // ~40K re-sent ≈ 1.8M, every request under ~60K). Compacting at
      // half-spend shrinks every subsequent request and stretches the cap for
      // exactly the runs that need it. tin-cmpt: the fallback baseline is
      // what keeps the trigger alive without a cap — the old code's
      // `limit == null → false` removed the spend trigger AND the hard abort
      // at once, so nothing forced a checkpoint for a whole long turn.
      // Either way the older history is summarized in place (keeping the
      // trailing messages verbatim) and that goes out instead. Same estimate
      // [checkRequestInput]
      // uses; compaction failure is non-fatal and rate-limited by the attempt
      // gate above. Runs BEFORE the per-request rejection so a payload that
      // crossed both thresholds gets compacted first — the cap then judges
      // the compacted history, and only rejects when even compaction couldn't
      // bring it down.
      //
      // The splittability pre-check (boundary ≥ 2 ⇒ a prefix of at least two
      // messages) costs no request: a history that is still all-current-turn
      // must not consume the attempt gate, or the gate would postpone the
      // first real compaction by its whole window.
      //
      // `autoCompactThreshold == 0` disables BOTH triggers (0 = feature off;
      // the spend trigger refines WHEN, not WHETHER, to compact).
      //
      // The per-turn spend LADDER (#43), in firing order: 50% of
      // perTurnLimit (or, uncapped, [kNoCapTurnSpendCompactRatio] of the
      // auto-compact threshold — tin-cmpt) — one in-place compaction (this
      // block; the latch [_turnSpendCompactFired] bounds it to a single
      // attempt per turn) → 90% — the soft margin's one in-band "finish up"
      // nudge (#37, checked after each record below; capped turns only) →
      // 100% — the hard budget abort (below; capped turns only). The
      // uncapped branch has no later rungs, which is why the compaction
      // rung — and the tin-cmpt no-checkpoint advisory — carry the whole
      // turn.
      // Aged large tool_result stubbing (#44): between steps, any
      // tool_result block whose serialized body exceeds the threshold
      // (4KB) and which is older than the retention window (8 steps back)
      // is replaced IN PLACE with a short text stub; pairing stays
      // intact (`tool_use_id` preserved). Silent, deterministic, no
      // LLM call — runs BEFORE any compaction pass so the two compose:
      // stubbing trims the steady-state context, compaction handles the
      // rest. A history of all-small or all-recent results is a no-op.
      stubAgedToolResults(history, currentStep: step);

      if (autoCompactThreshold > 0 && step - lastCompactAttempt >= 3) {
        final estimate =
            TokenBudget.estimateInputTokens(system, history, stepTools.schemas);
        final sizeTriggered = estimate > autoCompactThreshold;
        // Spend trigger: the per-turn cap counts every round trip's
        // input+output, so a many-step turn on a mid-size context burns
        // through the cap even when no single request is large. The
        // predicate [TokenBudget.turnSpendCompactTrigger] owns the rung
        // arithmetic — 50% of the cap when one is set
        // (kTurnSpendCompactRatio, unchanged by tin-cmpt), an absolute
        // baseline of kNoCapTurnSpendCompactRatio × the threshold when it
        // is not — and is pure over the recorded totals. The latch below
        // bounds it to once per turn; the size floor
        // (estimate > threshold/2) skips compaction when the context is
        // small enough that compacting buys little.
        final spendTriggered = !_turnSpendCompactFired &&
            budget?.turnSpendCompactTrigger(
                  autoCompactThreshold: autoCompactThreshold,
                ) ==
                true &&
            estimate > autoCompactThreshold ~/ 2;
        if ((sizeTriggered || spendTriggered) &&
            _assistantMessageBoundary(history, autoCompactKeepMessages) >= 2) {
          if (spendTriggered && !sizeTriggered) {
            final noticeLine = budget!.perTurnLimit != null
                ? '\n[compact] turn spend ${budget!.turnGrandTotal}/'
                    '${budget!.perTurnLimit} crossed '
                    '${(kTurnSpendCompactRatio * 100).round()}% '
                    '— compacting once to stretch the per-turn cap\n'
                : '\n[compact] turn spend ${budget!.turnGrandTotal} crossed '
                    '${(kNoCapTurnSpendCompactRatio * 100).round()}% of the '
                    'auto-compact threshold with no per-turn cap — compacting '
                    'once to checkpoint the turn\n';
            sink.notice(noticeLine, kind: NoticeKind.info);
          }
          lastCompactAttempt = step;
          _turnSpendCompactFired = true;
          await compact(history,
              preserveRecentMessages: autoCompactKeepMessages);
        }
      }

      // Pre-flight: refuse a request whose input alone would blow past the
      // per-request cap. Catches the "single tool returned 5MB of context"
      // scenario before we put it on the wire.
      final reject =
          budget?.checkRequestInput(system, history, stepTools.schemas);
      if (reject != null) {
        sink.notice('\n[budget] $reject\n', kind: NoticeKind.error);
        abortedReason = reject;
        abortedKind = AbortedKind.budget;
        return;
      }

      // #28: the transport-retry ladder. `outcome.error` with a
      // transport-retryable [TurnOutcome.streamError] and attempts remaining
      // re-sends this step from the UNCHANGED history: nothing was appended
      // for the failed step (content is null on error, so the flow below
      // never reached a history.add), the user message was appended ONCE by
      // the turn preamble above, and the ladder is INVISIBLE to the step loop
      // — the loop-back lands directly on the send. Cancel during the
      // backoff exits the turn cleanly, like any cancel. Exhausted (or 0
      // configured, or no metadata to classify with) falls through to the
      // historical abort below.
      var attemptsUsed = 0;
      TurnOutcome outcome;
      while (true) {
        final stream = provider.send(
          system: system,
          messages: history,
          tools: stepTools.schemas,
        );
        outcome = await const ProviderStreamConsumer()
            .consume(stream, sink: sink, cancelSignal: cancelSignal);
        final err = outcome.streamError;
        if (outcome.error == null ||
            err == null ||
            !isTransportRetryable(err) ||
            attemptsUsed >= transportRetryAttempts ||
            cancelled) {
          break;
        }
        attemptsUsed++;
        final delay = transportBackoffFor(
          attemptsUsed,
          retryAfter: err.retryAfter,
        );
        sink.notice(
          '\ntransport error: ${outcome.error} — retry '
          '$attemptsUsed/$transportRetryAttempts in ${delay.inSeconds}s\n',
          kind: NoticeKind.warning,
        );
        // Park on the backoff, honoring the cancel signal: a cancel that
        // lands mid-wait exits the turn cleanly instead of sleeping out the
        // full delay (mirrors [RetryingProvider]'s `Future.any` backoff).
        final timer = transportBackoffDelay != null
            ? transportBackoffDelay!(delay)
            : Future<void>.delayed(delay);
        if (cancelSignal != null) {
          await Future.any([timer, cancelSignal]);
        } else {
          await timer;
        }
        if (cancelled) {
          // Cancel during the backoff: exit the turn cleanly, exactly like a
          // cancel that landed mid-stream — the consumer already printed
          // [cancelled] for that path; print it for this one.
          sink.notice('\n[cancelled]\n', kind: NoticeKind.warning);
          abortedKind = AbortedKind.cancel;
          return;
        }
      }
      if (outcome.error != null) {
        sink.notice('\nerror: ${outcome.error}\n', kind: NoticeKind.error);
        abortedReason = outcome.error.toString();
        // #28: transport-retryable failures the ladder actually TRIED are a
        // distinct stop — the built-in retry is spent. With attempts at 0
        // (the TUI/library default) nothing was tried, so a retryable
        // failure keeps the pre-#28 [provider] classification that callers
        // like the sub-agent scheduler map to transient. Auth (401),
        // rate-limit-forever, and everything unclassified stay [provider].
        // Explicit account failures must not become scheduler-level retries.
        if (outcome.streamError?.requiresUserAction == true) {
          abortedKind = AbortedKind.providerTerminal;
        } else {
          abortedKind = attemptsUsed > 0 &&
                outcome.streamError != null &&
                isTransportRetryable(outcome.streamError!)
            ? AbortedKind.transport
            : AbortedKind.provider;
        }
        return;
      }
      if (outcome.cancelled) {
        // [cancelled] notice already printed by ProviderStreamConsumer before
        // the async stream teardown, so it appears in the panel immediately.
        return;
      }
      final content = outcome.content;
      if (content == null) {
        // Stream closed without ever yielding MessageComplete — server cut
        // us off mid-response, or the SSE framing was broken. Don't crash
        // on a null-assert; surface it and let the user retry.
        sink.notice('\nerror: stream ended without a complete response\n',
            kind: NoticeKind.error);
        abortedReason = 'stream ended without a complete response';
        abortedKind = AbortedKind.provider;
        return;
      }
      if (outcome.usage != null) {
        budget = budget?.record(outcome.usage!);
        // SOFT margin (#37): when the recorded spend FIRST reaches ~90% of
        // the per-turn cap, inject ONE user-role message into this turn's
        // history so the MODEL is told to land cleanly — a sink.notice here
        // would reach only the UI/stderr and be invisible to the model (the
        // #27 lesson: Run A's asker-refusal hint went to stderr and the model
        // spun on). The hard abort below stays exactly as it was.
        if (!_softMarginFired) {
          final soft = budget?.softMarginNotice();
          if (soft != null) {
            _softMarginFired = true;
            final softMessage =
                Message(role: Role.user, content: [TextBlock(soft)]);
            history.add(softMessage);
            final pendingSoft = _notifyAppend(softMessage);
            if (pendingSoft != null) await pendingSoft;
            // UI mirror: the transcript shows what the model was told. This
            // is convenience, not delivery — delivery happened above.
            sink.notice('\n$soft\n', kind: NoticeKind.warning);
          }
        }
        // tin-cmpt: the no-checkpoint advisory. On a turn with NO per-turn
        // cap there is no hard abort and no soft margin — the only walls left
        // are the compaction rungs — so a turn that burns spend while
        // touching no mutable tool can end with nothing on disk to show for
        // it. Once the spend crosses [kNoCheckpointAdvisorySpend] (absolute,
        // so the advisory survives a cap of 0) and no call to
        // [kCheckpointTouchTools] has been seen, inject ONE user-role message
        // the model reads (the #27 lesson: stderr never reaches the model)
        // telling it to land a checkpoint, and mirror it to the operator.
        // The latch makes it once per turn — it is a nudge, not a wall.
        if (budget != null &&
            !_checkpointAdvisoryFired &&
            budget!.turnGrandTotal >= kNoCheckpointAdvisorySpend) {
          if (!turnTouchedCheckpoint) {
            _checkpointAdvisoryFired = true;
            final advisoryMessage = Message(
                role: Role.user, content: [TextBlock(kNoCheckpointAdvisoryLine)]);
            history.add(advisoryMessage);
            final pendingAdvisory = _notifyAppend(advisoryMessage);
            if (pendingAdvisory != null) await pendingAdvisory;
            sink.notice('\n$kNoCheckpointAdvisoryLine\n',
                kind: NoticeKind.warning);
          }
          // A turn that HAS touched a mutable tool never gets the advisory;
          // the latch stays unset but the check is cheap and turn-scoped.
        }
        final kind = budget?.exceededLimit();
        if (kind != null) {
          if (pauseGate != null && kind == TokenLimitKind.perSession) {
            // Per-session trip: pause ALL agents and ask the user. The tripped
            // response wasn't appended to history yet (that's below), so after
            // a reset the loop re-sends cleanly. Both Continue and Abort reset
            // this agent's session counter (Abort otherwise re-trips on the
            // very next turn); the decision only changes whether this turn
            // resumes or aborts.
            pauseGate!.requestPause(budget!.exceeded()!);
            final cont =
                await pauseGate!.waitForResume(cancelSignal: cancelSignal);
            budget = budget?.resetSession();
            if (!cont) {
              sink.notice('\n[budget] session limit — turn aborted\n',
                  kind: NoticeKind.warning);
              abortedReason = 'session limit — turn aborted';
              abortedKind = AbortedKind.budget;
              return;
            }
            continue; // resume the loop; next iteration re-sends the request
          }
          sink.notice('\n[budget] ${budget!.exceeded()}\n',
              kind: NoticeKind.error);
          abortedReason = budget!.exceeded();
          abortedKind = AbortedKind.budget;
          return;
        }
      }

      final emptyCause = classifyEmptyCompletion(content, outcome.stopReason);
      if (emptyCause == EmptyCompletionCause.outputLimit ||
          emptyCause == EmptyCompletionCause.filtered) {
        final reason = emptyCause == EmptyCompletionCause.outputLimit
            ? 'model reached its output token limit without producing an answer '
                '(finish reason: ${outcome.stopReason}); increase --max-tokens '
                'or reduce the model\'s reasoning budget before retrying'
            : 'provider filtered the response without producing an answer '
                '(finish reason: ${outcome.stopReason})';
        sink.notice('\nerror: $reason\n', kind: NoticeKind.error);
        abortedReason = reason;
        abortedKind = AbortedKind.providerTerminal;
        return;
      }

      // A completion with no usable content is degenerate — seen in the wild
      // as a 200 whose body carries zero content (an overloaded worker
      // "answering" with nothing: NIM's poolside/laguna under worker
      // exhaustion). Ending the turn here would read as a clean finish, and
      // a headless run would exit 0 having done nothing. Retry with backoff — a
      // re-send lands on the next member when the provider is pooled — and
      // abort loudly if it repeats. Either way the empty message is NOT
      // appended to history: it says nothing, and some providers reject an
      // empty assistant message on the next request.
      if (emptyCause == EmptyCompletionCause.transient) {
        if (emptyCompletions < emptyCompletionRetryAttempts) {
          emptyCompletions++;
          final delay = Duration(seconds: 1 << (emptyCompletions - 1).clamp(0, 4));
          sink.notice('\n[provider] empty completion — retry '
              '$emptyCompletions/$emptyCompletionRetryAttempts in ${delay.inSeconds}s (Ctrl+C to cancel)\n',
              kind: NoticeKind.warning);
          if (emptyCompletionBackoffDelay != null) {
            final wait = emptyCompletionBackoffDelay!(delay);
            await (cancelSignal == null ? wait : Future.any<void>([wait, cancelSignal]));
          } else {
            final ready = Completer<void>();
            final timer = Timer(delay, ready.complete);
            try {
              await (cancelSignal == null ? ready.future : Future.any<void>([ready.future, cancelSignal]));
            } finally {
              timer.cancel();
            }
          }
          // Empty responses are retries of this step, not additional tool steps.
          step--;
          continue;
        }
        sink.notice('\nerror: model returned an empty completion\n',
            kind: NoticeKind.error);
        abortedReason = 'model returned an empty completion';
        abortedKind = AbortedKind.provider;
        return;
      }
      if (emptyCompletions > 0) {
        sink.notice('\n[provider] response recovered — continuing\n');
      }
      emptyCompletions = 0;

      final assistantMessage = Message(role: Role.assistant, content: content);
      history.add(assistantMessage);
      // Written-through as soon as it exists: the assistant message carries
      // the tool_use blocks the next step answers, so losing it on a kill
      // orphans the tool results that follow. Awaited so a turn exit (cancel,
      // error, clean finish) can never outrun the observer.
      final pendingAssistant = _notifyAppend(assistantMessage);
      if (pendingAssistant != null) await pendingAssistant;

      final toolUses = content.whereType<ToolUseBlock>().toList();
      if (toolUses.isEmpty) {
        return;
      }

      final results = <ContentBlock>[];
      // Operator interrupt (#31), batch-scope attribution. The signal is
      // sampled when the batch STARTS and again right after every call:
      //
      //  * fired before the batch → index 0: call 1 is the "in flight" one.
      //    It STILL EXECUTES — through the interrupt-armed cancel seam, so a
      //    killable tool stops promptly and the prefix lands over a real
      //    result ("call 1 prefixed as above"; its own isError is preserved).
      //    Remaining calls stub without executing. There is no further
      //    batch: the turn ends after this one.
      //  * fired while call N executes → index N: that call finishes (its
      //    result is prefixed) and later calls stub.
      //
      // Stream phases are never disturbed — the signal is only consulted
      // here and in the effective cancel wiring around tool.execute.
      var interruptedCallIndex = executorState.toolInterrupted ? 0 : -1;
      if (interruptedCallIndex == 0) {
        sink.notice('$kOperatorInterruptedLine\n');
      }
      for (final use in toolUses) {
        // Per-call dispatch is extracted: [ToolExecutor.execute] owns the
        // whole `for (final use in toolUses)` body (parse-error,
        // unknown-tool, mode-block, denial + circuit breaker, asker,
        // sandbox-retry gate, execution, verifier gate, anomaly guardrail),
        // verbatim, against the per-turn [ToolCallState] built above. The
        // loop HEADER stays here — cancel break, already-interrupted stub,
        // action-limit check, toolCalls++ — as do the batch-scope
        // attribution above, the post-batch stamp, and the early return
        // below.
        if (cancelled) break;
        final callIndex = results.length;
        if (interruptedCallIndex >= 0 && callIndex > interruptedCallIndex) {
          // Whole-batch invariant: every tool_use still gets its
          // tool_result. Later calls of the batch stub as errors without
          // executing.
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: kOperatorInterruptedStub,
            isError: true,
          ));
          continue;
        }
        if (toolCalls >= kMaxToolCallsPerRun) {
          sink.notice('\n[action limit] reached, stopping\n',
              kind: NoticeKind.warning);
          abortedReason = 'action limit reached, stopping';
          abortedKind = AbortedKind.steps;
          return;
        }
        toolCalls++;
        // tin-cmpt: a call to a mutable tool means this turn has left (or is
        // about to leave) something on disk or in history — a checkpoint
        // exists, and the no-checkpoint advisory must never fire. Recorded
        // per CALL so a batch mixing edit and read still counts. Kept in the
        // loop header (not inside [ToolExecutor.execute]) so it counts every
        // attempted call exactly as before the dispatch was extracted.
        if (kCheckpointTouchTools.contains(use.name)) {
          turnTouchedCheckpoint = true;
        }
        final outcome = await toolExecutor.execute(
          use: use,
          stepTools: stepTools,
          step: step,
          isCancelled: () => cancelled,
        );
        results.add(outcome.result);
        if (outcome.interruptedInFlight) interruptedCallIndex = callIndex;
      }
      // Operator interrupt (#31), in-flight stamp — ONE site so the line
      // lands no matter which path produced that call's result (normal
      // return, thrown-tool catch, malformed-arguments, denied). The
      // in-flight call keeps its own result under the operator line and its
      // own isError; the batch is otherwise untouched. toolComplete for the
      // in-flight call already shipped above (the stamp never reaches
      // observers retroactively — history and the live strip can disagree
      // for this one call by design: the strip saw it happen live).
      if (interruptedCallIndex >= 0 &&
          interruptedCallIndex < results.length &&
          results[interruptedCallIndex] is ToolResultBlock) {
        final first = results[interruptedCallIndex] as ToolResultBlock;
        results[interruptedCallIndex] = ToolResultBlock(
          toolUseId: first.toolUseId,
          content: '$kOperatorInterruptedLine\n${first.content}',
          isError: first.isError,
        );
      }

      final toolResults = Message(role: Role.user, content: results);
      history.add(toolResults);
      // Written-through immediately: a kill after the tools ran but before the
      // next completion would otherwise lose the results while the on-disk
      // assistant message already references them (a dangling tool_use).
      final pendingResults = _notifyAppend(toolResults);
      if (pendingResults != null) await pendingResults;

      // Operator interrupt (#31): the batch is complete and recorded — the
      // whole-batch invariant holds and history is consistent. End the turn
      // CLEANLY: return from [run] normally — no `[cancelled]` notice, no
      // abort, abortedKind stays none. The next provider step is never
      // taken; the queued operator input starts a fresh turn.
      if (interruptedCallIndex >= 0) return;
    }

    sink.notice('(max steps reached)\n', kind: NoticeKind.warning);
    abortedReason = 'max steps reached';
    abortedKind = AbortedKind.steps;
  }

  /// Replace (part of) [history] with a summarized user+assistant exchange.
  /// Streams the summary so the user can see what was kept; on failure the
  /// original history is left untouched. Returns true if the history was
  /// actually compacted, false if it was skipped (empty, too little to
  /// summarize, or the summary failed).
  ///
  /// [preserveRecent] (default 0) keeps the most recent turns intact and
  /// summarizes only the older prefix. It counts *human turns* (user messages
  /// carrying text, not tool-result messages), and the split always lands on a
  /// human-turn boundary — never between a tool_use and its tool_result — so the
  /// preserved suffix stays a valid conversation the provider will accept. 0
  /// summarizes the whole history (the `/compact` behavior).
  ///
  /// [preserveRecentMessages] is the mid-turn variant: keep the last N
  /// *messages* verbatim instead of counting human turns — mid-turn there is
  /// often just one human turn (the current input), which the human-turn mode
  /// can't split around. The boundary walks back to the nearest assistant
  /// message, so the suffix starts on an assistant turn and a tool_use and its
  /// tool_result can never be separated (the tool_result always directly
  /// follows its tool_use's assistant message). Ignored when
  /// [preserveRecent] is set.
  Future<bool> compact(List<Message> history,
      {int preserveRecent = 0,
      int preserveRecentMessages = 0,
      Future<void>? cancelSignal}) async {
    if (history.isEmpty) {
      sink.notice('(nothing to compact)\n');
      return false;
    }

    final List<Message> prefix;
    final List<Message> suffix;
    if (preserveRecent > 0) {
      final split = _recentHumanTurnBoundary(history, preserveRecent);
      if (split <= 0) return false; // fewer recent human turns than requested
      prefix = history.sublist(0, split);
      suffix = history.sublist(split);
      if (prefix.length < 2)
        return false; // not enough older context to summarize
    } else if (preserveRecentMessages > 0) {
      final split = _assistantMessageBoundary(history, preserveRecentMessages);
      if (split <= 0) return false; // no safe boundary with a splittable prefix
      prefix = history.sublist(0, split);
      suffix = history.sublist(split);
      if (prefix.length < 2)
        return false; // not enough older context to summarize
    } else {
      prefix = history;
      suffix = const [];
    }

    final priorCount = history.length;
    final summaryRequest = [
      ...prefix,
      const Message(role: Role.user, content: [
        TextBlock(
            'Summarize the conversation above following the system instructions.'),
      ]),
    ];

    sink.notice(preserveRecent > 0
        ? '--- compacting $priorCount messages (keeping ${suffix.length} recent) ---\n'
        : '--- compacting $priorCount messages ---\n');

    final stream = provider.send(
      system: _compactSystemPrompt,
      messages: summaryRequest,
      tools: const [],
    );

    final buf = StringBuffer();
    final done = Completer<void>();
    Object? err;
    var sawText = false;

    // Cancellation waits for the stream subscription before returning, so a
    // closing conversation never releases its provider underneath compaction.
    final subscription = stream.listen(
      (event) {
        try {
          if (event is TextDelta) {
            if (!sawText) {
              sink.activityStop();
              sawText = true;
            }
            sink.text(event.text);
            buf.write(event.text);
          } else if (event is StreamError) {
            err = event.error;
          }
        } catch (e) {
          err = e;
          if (!done.isCompleted) done.complete();
        }
      },
      onDone: () {
        try {
          sink.activityStop();
          if (sawText) sink.newline();
        } catch (e) {
          err = e;
        } finally {
          if (!done.isCompleted) done.complete();
        }
      },
      onError: (Object e) {
        err = e;
        try {
          sink.activityStop();
        } catch (_) {}
        if (!done.isCompleted) done.complete();
      },
    );
    try {
      final cancelled = await Future.any([
        done.future.then((_) => false),
        if (cancelSignal != null) cancelSignal.then((_) => true),
      ]);
      if (cancelled) return false;
    } finally {
      await subscription.cancel();
    }

    if (err != null) {
      sink.notice('compact failed: $err\n', kind: NoticeKind.error);
      return false;
    }
    final summary = buf.toString().trim();
    if (summary.isEmpty) {
      sink.notice('compact failed: empty summary\n', kind: NoticeKind.error);
      return false;
    }

    // Signal the rewrite to the observer: compact is a REWRITE (clear +
    // rebuild), not an append. No synthetic marker message is appended — the
    // marker used to fire BEFORE the rebuild (and only when a replace-capable
    // observer was wired), so append-only observers saw a phantom message and
    // replace-capable ones could miss the rewrite entirely. Nor are the
    // rebuilt messages re-appended: an append-only recorder would duplicate
    // the kept suffix (those messages were already appended when they first
    // happened). The replace seam below fires ONCE with the final post-compact
    // list, after the history is fully rebuilt.
    final rebuilt = [
      Message(
          role: Role.user,
          content: [TextBlock('Prior conversation summary:\n\n$summary')]),
      const Message(
          role: Role.assistant,
          content: [TextBlock('Got it — continuing from this summary.')]),
      ...suffix,
    ];
    final after = rebuilt.length;
    history
      ..clear()
      ..addAll(rebuilt);
    final pendingReplace = _notifyReplace(history);
    if (pendingReplace != null) await pendingReplace;
    sink.notice('--- compacted $priorCount → $after messages ---\n');
    return true;
  }

  /// Moved to tool_executor.dart in the mechanical tool-dispatch extraction:
  /// [anomalySignature], [_collapseWhitespace] (private there), and
  /// [isAnomalousResult] are now top-level in tool_executor.dart; [Agent]
  /// keeps these delegating statics so every existing caller and test is
  /// untouched.
  static String anomalySignature(String toolName, Map<String, dynamic> input) =>
      tool_executor.anomalySignature(toolName, input);

  static bool isAnomalousResult(
    ToolResult result, {
    String? previousContent,
  }) =>
      tool_executor.isAnomalousResult(result, previousContent: previousContent);

  /// Index in [history] of the [keep]-th-most-recent *human* turn (a user
  /// message carrying a [TextBlock], not a tool-result message), so [compact]
  /// can split the history there. Cutting at a human-turn boundary never severs
  /// a tool_use/tool_result pair — those are an assistant→user(toolresult)
  /// sequence, a different user-message shape. Returns 0 if there are fewer than
  /// [keep] human turns (nothing to split off as a prefix).
  static int _recentHumanTurnBoundary(List<Message> history, int keep) {
    var humanTurns = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      final m = history[i];
      if (m.role == Role.user && m.content.any((b) => b is TextBlock)) {
        humanTurns++;
        if (humanTurns == keep) return i;
      }
    }
    return 0;
  }

  /// Largest split index that leaves at least [keep] messages in the suffix
  /// AND starts the suffix on an assistant message — the message-boundary
  /// analogue of [_recentHumanTurnBoundary] for mid-turn compaction, where the
  /// recent tail is a run of tool exchanges rather than human turns. Starting
  /// the suffix on an assistant message keeps every `assistant(tool_use)` next
  /// to its `user(tool_result)`: the pair is either both summarized (split
  /// after the tool_result) or both preserved (split at/before the tool_use).
  /// Returns 0 when no such boundary exists (the whole history is the recent
  /// exchange — nothing safely splittable).
  static int _assistantMessageBoundary(List<Message> history, int keep) {
    for (var i = history.length - keep; i >= 1; i--) {
      if (history[i].role == Role.assistant) return i;
    }
    return 0;
  }
}
