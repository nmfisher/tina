import 'dart:async';

import 'package:classifier/judgments.dart';
import 'package:tina_engine/tina_engine.dart';

/// Applies the app's shared quota to actual judgment attempts. Cache hits never
/// reach this decorator. Batch reservations remain independent admission limits;
/// they are not reported as measured spend.
class MeteredJudgmentService implements JudgmentService {
  final JudgmentService inner;
  final SpendLedger ledger;
  final PauseGate? pauseGate;
  final JudgmentRequestBudget budget;
  final int outputTokenAllowance;

  MeteredJudgmentService({
    required this.inner,
    required this.ledger,
    required this.budget,
    required this.outputTokenAllowance,
    this.pauseGate,
  }) {
    if (outputTokenAllowance <= 0) {
      throw ArgumentError.value(outputTokenAllowance, 'outputTokenAllowance');
    }
  }

  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    void checkCancellation() {
      if (cancellation?.isCancelled ?? false) {
        throw const JudgmentException(
          JudgmentFailure.cancelled,
          attempted: false,
        );
      }
    }

    void checkLedger() {
      if (ledger.tripped) {
        throw const JudgmentException(
          JudgmentFailure.budgetExceeded,
          attempted: false,
        );
      }
    }

    checkCancellation();
    final estimatedInput = budget.check(request);
    final stopped = Completer<void>();
    final detach = cancellation?.listen(() => stopped.complete());
    try {
      if (pauseGate != null &&
          !await pauseGate!.waitForResume(cancelSignal: stopped.future)) {
        throw const JudgmentException(
          JudgmentFailure.cancelled,
          attempted: false,
        );
      }
      checkCancellation();
      checkLedger();
      if (!await ledger.acquireRequestSlot(cancelSignal: stopped.future)) {
        throw const JudgmentException(
          JudgmentFailure.cancelled,
          attempted: false,
        );
      }
      checkCancellation();
      checkLedger();
      JudgmentResult result;
      try {
        result = await inner.evaluate(request, cancellation: cancellation);
      } on JudgmentException catch (e) {
        // The same failure (e.g. service closure) can occur before or after
        // dispatch. Only an explicit rejection is known to have spent nothing.
        if (e.attempted) {
          _record(const JudgmentUsage(), estimatedInput);
        }
        rethrow;
      }
      _record(result.usage, estimatedInput);
      return result;
    } finally {
      detach?.call();
    }
  }

  void _record(JudgmentUsage usage, int estimatedInput) {
    // Record only known counters as measured. Missing counters remain unknown
    // in the returned result, with their allowance separately marked estimated.
    ledger.record(
      TokenUsage(
        inputTokens: usage.inputTokens ?? 0,
        outputTokens: usage.outputTokens ?? 0,
      ),
    );
    if (usage.inputTokens == null || usage.outputTokens == null) {
      ledger.recordEstimated(
        TokenUsage(
          inputTokens: usage.inputTokens == null ? estimatedInput : 0,
          outputTokens: usage.outputTokens == null ? outputTokenAllowance : 0,
          estimated: true,
        ),
      );
    }
  }
}
