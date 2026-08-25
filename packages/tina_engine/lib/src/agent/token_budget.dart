import 'dart:convert';

import '../llm/message.dart';
import '../llm/provider.dart';
import '../tools/tool.dart';

/// Caps on token consumption that protect against runaway loops (a tool that
/// keeps re-firing, a malformed prompt that produces unbounded output, etc).
///
/// All three limits are optional; null = unbounded. Defaults are tuned to be
/// *generous* — a normal coding session should never hit them — and only
/// catch obvious malfunctions.

/// Which cumulative token cap is currently crossed, reported by
/// [TokenBudget.exceededLimit]. `null` = within budget. Lets callers
/// distinguish a per-session trip — which pauses all agents for a user
/// continue/abort decision — from a per-turn trip, which still hard-aborts.
enum TokenLimitKind { perTurn, perSession }

/// Fraction of the per-turn token cap at which [TokenBudget.softMarginNotice]
/// starts reporting the turn's SOFT margin (#37): the recorded spend has
/// reached ~90% of the limit, so the model gets ONE in-band nudge to land
/// cleanly before the hard abort at 100%. Named constant so it is tunable and
/// unit-testable; the hard-abort comparison (`turnTotal > perTurnLimit`) is
/// untouched by it.
const double kPerTurnSoftMarginRatio = 0.9;

/// Fraction of the per-turn token cap at which the agent's mid-turn
/// auto-compact fires on CUMULATIVE spend (#43): when `turnTotal` FIRST
/// crosses this share of `perTurnLimit`, the older history is summarized in
/// place — the same compaction the request-size trigger runs — so every
/// subsequent request shrinks before the cap trips. #42's measurement is why
/// the trigger exists: a 45-step turn on a mid-size context spends
/// cumulatively (steps × re-sent context ≈ 1.8M) while no single request ever
/// grows "large", so the request-size threshold alone fired too late to
/// matter. With the soft margin this completes the spend ladder: compact at
/// 50% → soft nudge at 90% ([kPerTurnSoftMarginRatio]) → hard abort at 100%
/// (`exceededLimit`, untouched). Named constant beside the soft-margin ratio
/// so both rungs of the ladder are tunable in one place; requires an
/// auto-compact threshold > 0 (0 disables compaction entirely).
const double kTurnSpendCompactRatio = 0.5;

/// Immutable accumulator of token spend against the three caps. [record]
/// returns a new [TokenBudget] with the totals advanced; [resetTurn] /
/// [resetSession] return one with a total zeroed. The owner (an [Agent])
/// reassigns its field on every update, so the live totals live in one place —
/// read them through `agent.budget`, not a reference captured before the turn
/// (a captured reference is frozen at the value it first saw and never sees
/// later `record`s).
class TokenBudget {
  /// Sum of input+output tokens within a single `Agent.run` call (one user
  /// message → possibly many provider round-trips).
  final int? perTurnLimit;

  /// Sum across the whole REPL session. Resets on `/clear` via [resetSession].
  final int? perSessionLimit;

  /// Approximate input-token cap on a single request. Computed pre-flight
  /// from the serialized prompt; aborts before we even hit the wire.
  final int? perRequestInputLimit;

  /// Running total of input+output tokens within the current `Agent.run` call,
  /// capped by [perTurnLimit]. Zeroed at the start of each run by [resetTurn].
  /// MEASURED spend only.
  final int turnTotal;

  /// Running total of input+output tokens across the whole REPL session,
  /// capped by [perSessionLimit]. Zeroed by [resetSession] (on `/clear` and
  /// after a per-session pause is resolved).
  /// MEASURED spend only.
  final int sessionTotal;

  /// #46 (b): running total of ESTIMATED tokens within the current turn — the
  /// floor booked from failed transport attempts that carried no
  /// provider-reported usage. Counts toward the same [perTurnLimit] ceiling so
  /// a runaway retry ladder trips it like measured spend would.
  final int turnEstimated;

  /// #46 (b): running total of ESTIMATED tokens across the session. Same cap
  /// arithmetic applies.
  final int sessionEstimated;

  const TokenBudget({
    this.perTurnLimit,
    this.perSessionLimit,
    this.perRequestInputLimit,
    this.turnTotal = 0,
    this.sessionTotal = 0,
    this.turnEstimated = 0,
    this.sessionEstimated = 0,
  });

  /// Copy with the given totals replaced. Caps are carried over unchanged.
  TokenBudget _copyWith(
          {int? turnTotal,
          int? sessionTotal,
          int? turnEstimated,
          int? sessionEstimated}) =>
      TokenBudget(
        perTurnLimit: perTurnLimit,
        perSessionLimit: perSessionLimit,
        perRequestInputLimit: perRequestInputLimit,
        turnTotal: turnTotal ?? this.turnTotal,
        sessionTotal: sessionTotal ?? this.sessionTotal,
        turnEstimated: turnEstimated ?? this.turnEstimated,
        sessionEstimated: sessionEstimated ?? this.sessionEstimated,
      );

  /// Zero the per-turn totals, keeping the session total. Called at the start
  /// of each `Agent.run`.
  TokenBudget resetTurn() =>
      _copyWith(turnTotal: 0, turnEstimated: 0);

  /// Zero all totals. Called by `/clear` and after a per-session pause is
  /// resolved (Continue or Abort both reset, so the next turn starts clean).
  TokenBudget resetSession() => _copyWith(
      turnTotal: 0, sessionTotal: 0, turnEstimated: 0, sessionEstimated: 0);

  /// Record one request's MEASURED usage (provider-reported). Sums
  /// `input + output` into both running totals and returns the updated
  /// budget. Usage flagged [TokenUsage.estimated] is routed to
  /// [recordEstimated] so the two counters can never be conflated.
  TokenBudget record(TokenUsage usage) {
    if (usage.estimated) return recordEstimated(usage);
    final used = usage.inputTokens + usage.outputTokens;
    return _copyWith(
      turnTotal: turnTotal + used,
      sessionTotal: sessionTotal + used,
    );
  }

  /// #46 (b): record one failed transport attempt's ESTIMATED usage — the
  /// size of the body it re-sent when its error carried no provider-reported
  /// numbers. The estimate counts toward the SAME caps ([perTurnLimit],
  /// [perSessionLimit]) — the point of #46: those caps read LOW today because
  /// failed-attempt spend was invisible — but it lives in its own counters
  /// ([turnEstimated], [sessionEstimated]) so it never masquerades as
  /// measured.
  TokenBudget recordEstimated(TokenUsage usage) {
    final used = usage.inputTokens + usage.outputTokens;
    return _copyWith(
      turnEstimated: turnEstimated + used,
      sessionEstimated: sessionEstimated + used,
    );
  }

  /// The per-turn cap arithmetic over the COMBINED measured+estimated spend:
  /// this is the number the hard abort, the #43 compaction rung and the #37
  /// soft-margin rung all compare against. Estimated spend raises these
  /// readings exactly like measured spend would.
  int get turnGrandTotal => turnTotal + turnEstimated;

  /// Which cumulative cap (if any) is currently crossed, or null if within
  /// budget. Call after each [record]. The agent uses this to apply the
  /// pause+dialog resolution only to per-session trips.
  ///
  /// #46: the per-turn and per-session comparisons read the COMBINED
  /// measured+estimated total — estimated spend trips the caps like measured
  /// spend, which is the point (a runaway retry ladder must trip them even
  /// when the ladder itself dies mid-flight and never reaches a
  /// MessageComplete).
  TokenLimitKind? exceededLimit() {
    final turnGrand = turnTotal + turnEstimated;
    final sessionGrand = sessionTotal + sessionEstimated;
    if (perTurnLimit != null && turnGrand > perTurnLimit!) {
      return TokenLimitKind.perTurn;
    }
    if (perSessionLimit != null && sessionGrand > perSessionLimit!) {
      return TokenLimitKind.perSession;
    }
    return null;
  }

  /// Returns a human-readable reason if a cumulative cap has been crossed,
  /// or null if we're still within budget. Call after each [record].
  String? exceeded() {
    final turnGrand = turnTotal + turnEstimated;
    final sessionGrand = sessionTotal + sessionEstimated;
    switch (exceededLimit()) {
      case TokenLimitKind.perTurn:
        return 'per-turn token budget exceeded '
            '($turnGrand > $perTurnLimit, of which '
            '$turnEstimated estimated). Aborting to prevent runaway cost. '
            'Raise with --max-turn-tokens.';
      case TokenLimitKind.perSession:
        return 'per-session token budget exceeded '
            '($sessionGrand > $perSessionLimit, of which '
            '$sessionEstimated estimated). Aborting to prevent runaway '
            'cost. Raise with --max-session-tokens, or /clear to reset.';
      case null:
        return null;
    }
  }

  /// The soft-margin notice (#37), or null if the per-turn soft margin has
  /// not been reached yet.
  ///
  /// [exceeded] reports the HARD abort (spend strictly above 100% of the
  /// cap). This method reports the SOFT margin: the recorded spend has
  /// reached [kPerTurnSoftMarginRatio] (90%) of the per-turn limit while
  /// still within budget. It is a pure predicate over [turnTotal] and
  /// [perTurnLimit] — the same source [exceeded] reads — so it can never
  /// fire after a hard trip (once `turnTotal > perTurnLimit`, [exceeded]
  /// already won) and it re-fires on every call after the threshold is
  /// crossed: callers must latch their own once-per-turn flag (the agent
  /// does), exactly like the denial counter does for #27.
  ///
  /// The returned text is what the agent injects into the turn's history as
  /// a user-role message so the MODEL sees it (a UI-only `sink.notice`
  /// never reaches the model — lesson #27); the message text is the seam
  /// tests assert against.
  String? softMarginNotice() {
    final limit = perTurnLimit;
    final grand = turnTotal + turnEstimated;
    if (limit == null || grand < (limit * kPerTurnSoftMarginRatio).ceil()) {
      return null;
    }
    if (exceededLimit() != null) return null; // hard trip: the hard reason wins
    return '[budget] turn spend at ${(kPerTurnSoftMarginRatio * 100).round()}%'
        ' (${grand} of $limit tokens, of which $turnEstimated estimated) of '
        'the per-turn limit — finish the current step and write your closing '
        'summary now; the turn is aborted hard when the remaining spend is '
        'exhausted.';
  }

  /// True when the recorded spend has FIRST crossed the #43 compaction rung
  /// — `turnTotal` has reached [kTurnSpendCompactRatio] (50%) of the
  /// per-turn limit while still within the cap. Pure over [turnTotal] and
  /// [perTurnLimit] — the same source [exceeded] reads — so it can never
  /// report true after a hard trip (once `turnTotal > perTurnLimit`,
  /// [exceeded] already won). Like [softMarginNotice] it re-fires on every
  /// call after the threshold is crossed: callers must latch their own
  /// once-per-turn flag (the agent does). The agent pairs this predicate
  /// with the auto-compact threshold's own size floor at the call site, so
  /// a mid-size cap doesn't force compaction of a context so small that
  /// compacting buys nothing. Null (no per-turn limit) → false: with no cap
  /// there is no fraction to cross.
  bool turnSpendCompactTrigger() {
    final limit = perTurnLimit;
    final grand = turnTotal + turnEstimated;
    if (limit == null || grand < (limit * kTurnSpendCompactRatio).ceil()) {
      return false;
    }
    return exceededLimit() == null; // hard trip: the hard reason wins
  }

  /// Pre-flight check on a request's input size. Approximates token count as
  /// `bytes / 4` from the wire-format string lengths — cheap and within a
  /// factor of ~2 of reality, which is enough for a runaway guard.
  String? checkRequestInput(
    String system,
    List<Message> messages,
    List<ToolSchema> tools,
  ) {
    if (perRequestInputLimit == null) return null;
    final bytes = _estimateInputBytes(system, messages, tools);
    final tokens = bytes ~/ 4;
    if (tokens > perRequestInputLimit!) {
      return 'request input estimate ~$tokens tokens exceeds '
          '--max-request-tokens ($perRequestInputLimit). The most recent '
          'tool output may be too large — try a more targeted command. '
          'Raise the cap with --max-request-tokens.';
    }
    return null;
  }

  /// Rough input-token estimate (`bytes / 4`) for a request shape — the same
  /// crude approximation [checkRequestInput] uses, exposed as a static so
  /// callers without a budget instance (e.g. auto-compact) can probe size.
  /// Within a factor of ~2 of reality, which is fine for a trigger threshold.
  static int estimateInputTokens(
          String system, List<Message> messages, List<ToolSchema> tools) =>
      _estimateInputBytes(system, messages, tools) ~/ 4;

  static int _estimateInputBytes(
    String system,
    List<Message> messages,
    List<ToolSchema> tools,
  ) {
    var total = system.length;
    for (final m in messages) {
      for (final b in m.content) {
        if (b is TextBlock) {
          total += b.text.length;
        } else if (b is ToolUseBlock) {
          total += b.name.length + jsonEncode(b.input).length;
        } else if (b is ToolResultBlock) {
          total += b.content.length;
        }
      }
    }
    for (final t in tools) {
      total += t.name.length +
          t.description.length +
          jsonEncode(t.inputSchema).length;
    }
    return total;
  }
}
