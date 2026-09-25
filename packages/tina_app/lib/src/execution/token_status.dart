import 'package:tina_engine/tina_engine.dart';

import 'input_status.dart';

/// A snapshot of the app session's token spend, for live display (the status
/// strip beneath the input). Mirrors the fields the spend display surfaces:
/// the measured total, the estimated failed-attempt bookings reported
/// distinctly, the optional ceiling, the trip latch, and the RPM throttle.
/// Pure data — the renderer decides presentation.
class TokenUsageSummary {
  /// Measured tokens this app session (input + output), all agents.
  final int totalTokens;

  /// Estimated failed-attempt bookings (re-sent bodies), shown distinctly.
  final int estimatedTokens;

  /// Tokens restored from a previous run via `SpendLedger.seed`.
  final int seededTokens;

  /// The global ceiling in effect, or null when unbounded.
  final int? cap;

  /// True once the ceiling was crossed.
  final bool tripped;

  /// Configured requests-per-minute throttle; 0 = disabled.
  final int rpm;

  const TokenUsageSummary({
    required this.totalTokens,
    required this.estimatedTokens,
    required this.seededTokens,
    required this.cap,
    required this.tripped,
    required this.rpm,
  });

  /// Capture the ledger's current state.
  factory TokenUsageSummary.of(SpendLedger ledger) => TokenUsageSummary(
    totalTokens: ledger.totalTokens,
    estimatedTokens: ledger.totalEstimatedTokens,
    seededTokens: ledger.seededTokens,
    cap: ledger.cap,
    tripped: ledger.tripped,
    rpm: ledger.rpm,
  );

  /// The combined total the trip arithmetic reads.
  int get grandTotal => totalTokens + estimatedTokens;

  /// Share of the ceiling consumed, 0..1, or null when unbounded.
  double? get capFraction {
    final c = cap;
    if (c == null || c <= 0) return null;
    return grandTotal / c;
  }
}

/// Exposes the app session's [SpendLedger] as a conversation-scoped
/// [StatusSource]: the ledger is app-session-scoped (one per app
/// composition), so every conversation reads the same snapshot; the `changes`
/// stream is the ledger's own, fired on every recorded request.
class LedgerTokenStatusSource implements StatusSource {
  final SpendLedger ledger;

  LedgerTokenStatusSource(this.ledger);

  @override
  Stream<void> get changes => ledger.changes;

  @override
  Object? read(String conversationId) => TokenUsageSummary.of(ledger);
}
