import 'dart:async';

import 'package:logging/logging.dart';

import '../llm/http.dart' show isTransportRetryable;
import '../llm/message.dart';
import '../llm/provider.dart';
import '../permissions/policy.dart';
import '../permissions/prompt.dart';
import '../tools/tool.dart';
import '../host/host_interface.dart';
import 'agent_sink.dart';
import 'pause_gate.dart';
import 'stream_consumer.dart';
import 'token_budget.dart';

final _log = Logger('tina.agent');

/// Hard-coded ceiling on tool invocations per turn. The run loop bounds *steps*
/// via [Agent.maxSteps] but not *tool uses* — this is the coarse backstop that
/// complements the token spend-funnel (~10× maxSteps=500, so legitimate
/// multi-file refactors have headroom; tool uses are serial per step). When
/// tripped the turn stops with a notice. `--yolo` can't extend it (it only
/// relaxes the ask-gate). No config surface by design.
const int kMaxToolCallsPerRun = 5000;

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

/// Consecutive denials of the SAME tool after which the denial result gains a
/// circuit-breaker line telling the model to stop calling that tool (#27).
/// Why 3: the live spiral runs wasted 12 steps (Run A) and 11 (the probe run)
/// re-denying one tool before the model gave up — three strikes is early
/// enough to cut most of that waste while leaving room for one legitimate
/// rephrase between attempts. Not configurable by design, like
/// [kMaxToolCallsPerRun].
const int _consecutiveDenialNoticeThreshold = 3;

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
int stubAgedToolResults(List<Message> history,
    {required int currentStep}) {
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
        content:
            '[elided after $ageSteps steps: $toolName result, '
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
/// completions, cut streams).
enum AbortedKind { none, provider, transport, budget, steps, cancel }

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

typedef ToolResultVerifier = Future<String?> Function(
  String toolName,
  Map<String, dynamic> input,
);

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
  /// on their own; budget/steps exhaustions and cancellations will not.
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

  /// Run one user turn. The agent may issue several provider calls if tools
  /// are invoked. [cancelSignal], when completed, aborts the current
  /// in-flight stream and exits the turn cleanly.
  ///
  /// The activity lifecycle is owned HERE, not by each caller: when the sink
  /// is a full host ([HostInterface]), the run raises its activity signal on
  /// entry and clears it on every exit path — the turn-in-flight semantics of
  /// HostInterface.setActivity (tin-y4qn). Callers that wrap a run with extra
  /// scope (the scheduler's job-level signal for panelized delegation, the
  /// environment ceremony's survey phase) may signal too; hosts treat repeats
  /// as idempotent. A sink that is only an [AgentSink] (telemetry sinks, the
  /// headless no-op) has no signal to drive and skips this.
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
  }) async {
    final HostInterface? activityHost =
        sink is HostInterface ? sink as HostInterface : null;
    activityHost?.setActivity(true);
    try {
      await _runTurn(
        history: history,
        userInput: userInput,
        cancelSignal: cancelSignal,
      );
    } finally {
      activityHost?.setActivity(false);
    }
  }

  Future<void> _runTurn({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
  }) async {
    abortedReason = null;
    abortedKind = AbortedKind.none;
    // The soft margin re-arms every turn: a new user turn gets its own one
    // nudge (the previous turn's spend is zeroed by resetTurn below).
    _softMarginFired = false;
    // Same for the 50%-spend compaction latch (#43): the previous turn's
    // compaction must not suppress this turn's.
    _turnSpendCompactFired = false;
    final userMessage =
        Message(role: Role.user, content: [TextBlock(userInput)]);
    history.add(userMessage);
    final pendingUser = _notifyAppend(userMessage);
    if (pendingUser != null) await pendingUser;

    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);
    budget = budget?.resetTurn();

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

    // Per-tool consecutive denial counter (#27): resets on any SUCCESS of
    // that tool, increments on each denial. Used to trip the circuit-breaker
    // message that tells the model to stop calling the same denied tool.
    final denialCounts = <String, int>{};

    // Soft margin (#37): the once-per-turn latch is the instance field
    // [_softMarginFired]; it resets here, at the top of every turn, so each
    // new turn gets exactly one nudge (a threshold re-fire would re-nag the
    // model on every step once spend stays past 90%).

    for (var step = 0; step < maxSteps; step++) {
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
      // every round trip) crossing half the per-turn cap while the estimate
      // is above half the threshold — the many-steps-on-a-mid-size-context
      // case (65K × 15 ≈ 1M) where no single request ever grows large
      // enough, but the cap keeps tripping (#42 measured exactly this shape:
      // 45 steps × ~40K re-sent ≈ 1.8M, every request under ~60K).
      // Compacting at half-spend shrinks every subsequent request and
      // stretches the cap for exactly the runs that need it. Either way the
      // older history is summarized in place (keeping the trailing messages
      // verbatim) and that goes out instead. Same estimate [checkRequestInput]
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
      // perTurnLimit — one in-place compaction (this block; the latch
      // [_turnSpendCompactFired] bounds it to a single attempt per turn) →
      // 90% — the soft margin's one in-band "finish up" nudge (#37, checked
      // after each record below) → 100% — the hard budget abort (below,
      // untouched). Compacting at the first rung is what keeps the later
      // rungs from being reached in a many-step turn.
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
            TokenBudget.estimateInputTokens(system, history, tools.schemas);
        final sizeTriggered = estimate > autoCompactThreshold;
        // Spend trigger: the per-turn cap counts every round trip's
        // input+output, so a many-step turn on a mid-size context burns
        // through the cap even when no single request is large. The
        // predicate [TokenBudget.turnSpendCompactTrigger] owns the 50% rung
        // of the ladder (named constant kTurnSpendCompactRatio; pure over
        // the recorded totals, false without a perTurnLimit); the latch
        // below bounds it to once per turn; the size floor
        // (estimate > threshold/2) skips compaction when the context is
        // small enough that compacting buys little.
        final spendTriggered =
            !_turnSpendCompactFired &&
                budget?.turnSpendCompactTrigger() == true &&
                estimate > autoCompactThreshold ~/ 2;
        if ((sizeTriggered || spendTriggered) &&
            _assistantMessageBoundary(history, autoCompactKeepMessages) >= 2) {
          if (spendTriggered && !sizeTriggered) {
            sink.notice(
                '\n[compact] turn spend ${budget!.turnTotal}/'
                '${budget!.perTurnLimit} crossed '
                '${(kTurnSpendCompactRatio * 100).round()}% '
                '— compacting once to stretch the per-turn cap\n',
                kind: NoticeKind.info);
          }
          lastCompactAttempt = step;
          _turnSpendCompactFired = true;
          await compact(history, preserveRecentMessages: autoCompactKeepMessages);
        }
      }

      // Pre-flight: refuse a request whose input alone would blow past the
      // per-request cap. Catches the "single tool returned 5MB of context"
      // scenario before we put it on the wire.
      final reject = budget?.checkRequestInput(system, history, tools.schemas);
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
          tools: tools.schemas,
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
        abortedKind = attemptsUsed > 0 &&
                outcome.streamError != null &&
                isTransportRetryable(outcome.streamError!)
            ? AbortedKind.transport
            : AbortedKind.provider;
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

      // A completion with NO blocks at all is degenerate — seen in the wild
      // as a 200 whose body carries zero content (an overloaded worker
      // "answering" with nothing: NIM's poolside/laguna under worker
      // exhaustion). Ending the turn here would read as a clean finish, and
      // a headless run would exit 0 having done nothing. Retry once — a
      // re-send lands on the next member when the provider is pooled — and
      // abort loudly if it repeats. Either way the empty message is NOT
      // appended to history: it says nothing, and some providers reject an
      // empty assistant message on the next request.
      if (content.isEmpty) {
        if (emptyCompletions == 0) {
          emptyCompletions++;
          sink.notice('\n[provider] empty completion — retrying\n',
              kind: NoticeKind.warning);
          continue;
        }
        sink.notice('\nerror: model returned an empty completion\n',
            kind: NoticeKind.error);
        abortedReason = 'model returned an empty completion';
        abortedKind = AbortedKind.provider;
        return;
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
      for (final use in toolUses) {
        if (cancelled) break;
        if (toolCalls >= kMaxToolCallsPerRun) {
          sink.notice('\n[action limit] reached, stopping\n',
              kind: NoticeKind.warning);
          abortedReason = 'action limit reached, stopping';
          abortedKind = AbortedKind.steps;
          return;
        }
        toolCalls++;
        // The model's tool-call arguments were not valid JSON (tin-p2sq: a
        // quote-heavy shell one-liner it failed to escape). The tool cannot
        // run, but the turn need not die: answer the call with an error the
        // model can act on, and let the next step re-emit it correctly.
        final parseError = use.argumentsParseError;
        if (parseError != null) {
          sink.notice(
              '  ${use.name}: malformed arguments — asking the model to '
              'retry\n',
              kind: NoticeKind.warning);
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: 'Your ${use.name} call was discarded: its arguments '
                'were not valid JSON ($parseError). This usually means '
                'quotes or backslashes in the command text were not escaped '
                'for JSON — re-emit the call with '
                r'inner double quotes written as \" and each literal '
                r'backslash as \\.',
            isError: true,
          ));
          continue;
        }
        final tool = tools[use.name];
        if (tool == null) {
          sink.notice('  unknown tool: ${use.name}\n', kind: NoticeKind.error);
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: 'Unknown tool: ${use.name}',
            isError: true,
          ));
          continue;
        }

        var decision = policy.check(use.name, use.input);
        // The asker's response, when the decision went through the asker
        // (ask → refused). Null for a static deny RULE — a rule deny is a
        // policy choice; the allowed-shapes text is its remedy, so no asker
        // note is expected there.
        PermissionResponse? resp;
        if (decision == PermissionDecision.ask) {
          final prompt = PermissionPrompt(use.name, use.input);
          resp = await asker(prompt);
          decision = resp.decision;
          if (resp.remember) {
            policy.remember(use.name, prompt.alwaysPattern, decision);
          }
        }
        if (decision == PermissionDecision.deny) {
          sink.notice('  ${use.name} denied\n');
          // Circuit breaker (#27): a model that keeps re-denying the SAME
          // tool never gets new information from the plain denial text, and
          // the asker's own refusal hint only went to stderr — so it spun
          // (12 wasted steps in Run A; 11 in the probe run). Past the
          // threshold the denial result itself says "stop calling this".
          final denials = (denialCounts[use.name] ?? 0) + 1;
          denialCounts[use.name] = denials;
          var content = _deniedContent(use.name);
          final note = resp?.note;
          if (note != null && note.isNotEmpty) {
            content = '$content\n$note';
          }
          if (denials >= _consecutiveDenialNoticeThreshold) {
            content =
                '$content\nNOTE: $denials consecutive ${use.name} denials '
                'this turn — this tool will keep being refused. Stop calling '
                'it; proceed with the allowed tools or answer from what you '
                'have.';
            sink.notice(
                '  ${use.name}: $denials consecutive denials this turn — '
                'circuit-breaker notice attached to the denial result\n',
                kind: NoticeKind.warning);
          }
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: content,
            isError: true,
          ));
          continue;
        }

        // An ALLOWED call resets this tool's denial streak — the policy
        // let the shape through, so the refusal pattern it was counting is
        // over (whether the execution then succeeds or errors).
        denialCounts.remove(use.name);
        sink.toolStart(ToolStartEvent(use.name, use.id, use.input));
        try {
          final out = await tool.execute(
            use.input,
            cancelSignal: cancelSignal,
            onOutput: (chunk, {bool stderr = false}) {
              sink.toolOutput(
                  ToolOutputEvent(use.name, use.id, chunk, stderr: stderr));
            },
          );
          sink.toolComplete(ToolCompleteEvent(use.name, use.id,
              isError: out.isError, result: out.content));
          // Success-only verifier gate (#22a): a post-tool check (e.g. a
          // headless post-edit `dart analyze`) can append a remediation block
          // to the result the model reads next step. Error results, the
          // parse-error / unknown-tool / denied / thrown paths above all skip
          // it, and a verifier crash must never kill the turn — the tool's
          // own content ships unchanged instead.
          if (!out.isError && resultVerifier != null) {
            try {
              final verdict = await resultVerifier!(use.name, use.input);
              if (verdict != null && verdict.isNotEmpty) {
                results.add(ToolResultBlock(
                  toolUseId: use.id,
                  content: '${out.content}\n$verdict',
                  isError: out.isError,
                ));
                continue;
              }
            } catch (e, st) {
              _log.warning(
                  'result verifier for ${use.name} failed — shipping the '
                  'tool content unchanged',
                  e,
                  st);
            }
          }
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: out.content,
            isError: out.isError,
          ));
        } catch (e, st) {
          // Route thrown-tool failures through the same toolComplete path so
          // a tool strip / observer learns about them too. (Previously this
          // printed the bare exception; it now renders like an error result.)
          _log.severe('unhandled exception in tool ${use.name}', e, st);
          sink.toolComplete(ToolCompleteEvent(use.name, use.id,
              isError: true, result: e.toString()));
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: e.toString(),
            isError: true,
          ));
        }
      }
      final toolResults = Message(role: Role.user, content: results);
      history.add(toolResults);
      // Written-through immediately: a kill after the tools ran but before the
      // next completion would otherwise lose the results while the on-disk
      // assistant message already references them (a dangling tool_use).
      final pendingResults = _notifyAppend(toolResults);
      if (pendingResults != null) await pendingResults;
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
      {int preserveRecent = 0, int preserveRecentMessages = 0}) async {
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

    // compact uses a simpler listen than ProviderStreamConsumer because it
    // only needs text deltas — no tool calls or usage tracking.
    stream.listen(
      (event) {
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
      },
      onDone: () {
        sink.activityStop();
        if (sawText) sink.newline();
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        sink.activityStop();
        err = e;
        if (!done.isCompleted) done.complete();
      },
    );

    await done.future;

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

  /// The remediation payload a denied tool call carries back to the model.
  /// The old one-liner ('Denied by permission policy.') gave the model no way
  /// to self-correct, so it retried blind variants of the same shape; the
  /// model now sees the allowed shapes for its tool and (for bash) the
  /// always-allowed native tools, and is told not to retry unchanged.
  String _deniedContent(String tool) {
    final patterns = policy.allowedPatterns(tool);
    final lines = <String>[
      'Denied by permission policy.',
      'Allowed $tool patterns: '
          '${patterns.isEmpty ? 'none' : patterns.join(', ')}',
      if (tool == 'bash')
        'For read-only checks prefer the always-allowed tools: ls, stat, '
            'glob, grep, search, git, which.',
      'Do not retry the same call unchanged; rephrase it to an allowed '
          'shape or use one of those tools.',
    ];
    return lines.join('\n');
  }

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
