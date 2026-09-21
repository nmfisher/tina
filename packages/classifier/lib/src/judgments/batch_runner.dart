import 'dart:async';

import 'models.dart';
import 'request_budget.dart';
import 'service.dart';

class JudgmentBatchLimits {
  final int concurrency;
  final int maxRequests;
  final int maxChargedTokens;
  final int outputTokenAllowance;
  final Duration requestTimeout;
  final Duration timeout;

  JudgmentBatchLimits({
    this.concurrency = 4,
    this.maxRequests = 256,
    required this.maxChargedTokens,
    required this.outputTokenAllowance,
    this.requestTimeout = const Duration(seconds: 30),
    this.timeout = const Duration(minutes: 2),
  }) {
    if (concurrency <= 0 ||
        maxRequests <= 0 ||
        maxChargedTokens <= 0 ||
        outputTokenAllowance <= 0 ||
        requestTimeout <= Duration.zero ||
        timeout <= Duration.zero) {
      throw ArgumentError('Judgment batch limits must be positive');
    }
  }
}

class JudgmentBatchItem {
  final JudgmentResult? result;
  final JudgmentFailure? failure;
  final bool attempted;
  const JudgmentBatchItem._(this.result, this.failure, this.attempted);
}

class JudgmentBatchResult {
  /// Input order, including unattempted work; completed evidence survives a
  /// timeout/cancellation. Failures never masquerade as empty valid judgments.
  final List<JudgmentBatchItem> items;

  /// Conservative admission accounting, NOT measured spend. Failed/unknown
  /// usage retains its reservation; complete measured usage replaces it.
  final int chargedTokens;
  const JudgmentBatchResult._(this.items, this.chargedTokens);
}

/// A bounded batch of independent requests. No filesystem, chat history,
/// persistence, retries, or nested delegation. Reuse sequentially; overlapping
/// runs are rejected so they cannot multiply the configured concurrency limit.
/// Services must honor cancellation (the Typesafe adapter closes its client).
class JudgmentBatchRunner {
  final JudgmentService service;
  final JudgmentRequestBudget budget;
  final JudgmentBatchLimits limits;
  bool _running = false;

  JudgmentBatchRunner(
      {required this.service, required this.budget, required this.limits});

  Future<JudgmentBatchResult> run(List<JudgmentRequest> requests,
      {JudgmentCancellation? cancellation}) async {
    if (_running) throw StateError('Judgment batch already running');
    if (requests.length > limits.maxRequests) {
      throw const JudgmentException(JudgmentFailure.budgetExceeded);
    }
    final work = List<JudgmentRequest>.of(requests);
    // Validate ALL inputs before spending anything.
    final reservations = [
      for (final request in work)
        budget.check(request) + limits.outputTokenAllowance
    ];
    _running = true;
    final stop = JudgmentCancellation();
    JudgmentFailure? stoppedReason;
    void halt(JudgmentFailure reason) {
      stoppedReason ??= reason;
      stop.cancel();
    }

    final unsubscribe =
        cancellation?.listen(() => halt(JudgmentFailure.cancelled));
    final timer = Timer(limits.timeout, () => halt(JudgmentFailure.timeout));
    final items = List<JudgmentBatchItem?>.filled(work.length, null);
    var next = 0;
    var charged = 0;
    var inFlight = 0;
    var settled = Completer<void>();
    Future<void> worker() async {
      while (next < work.length) {
        final index = next;
        if (stoppedReason != null) {
          next++;
          items[index] = JudgmentBatchItem._(null, stoppedReason, false);
          continue;
        }
        final reserved = reservations[index];
        // Reconsider the head of the queue after a reservation settles. Do not
        // let a newly available worker jump ahead of higher-priority requests.
        if (charged + reserved > limits.maxChargedTokens && inFlight > 0) {
          await settled.future;
          continue;
        }
        next++;
        if (charged + reserved > limits.maxChargedTokens) {
          items[index] = const JudgmentBatchItem._(
              null, JudgmentFailure.budgetExceeded, false);
          continue;
        }
        charged += reserved;
        inFlight++;
        final local = JudgmentCancellation();
        final interrupted = Completer<JudgmentResult>();
        void interrupt(JudgmentFailure reason) {
          if (!interrupted.isCompleted) {
            interrupted.completeError(JudgmentException(reason));
            local.cancel();
          }
        }

        final detach = stop.listen(() => interrupt(stoppedReason!));
        final callTimer = Timer(
            limits.requestTimeout, () => interrupt(JudgmentFailure.timeout));
        try {
          final result = await Future.any([
            Future.sync(
                () => service.evaluate(work[index], cancellation: local)),
            interrupted.future,
          ]);
          final usage = result.usage;
          final observed = (usage.inputTokens ?? budget.estimate(work[index])) +
              (usage.outputTokens ?? limits.outputTokenAllowance);
          if (usage.inputTokens != null && usage.outputTokens != null) {
            charged += observed - reserved;
          } else if (observed > reserved) {
            charged += observed - reserved;
          }
          items[index] = JudgmentBatchItem._(result, null, true);
          if (charged > limits.maxChargedTokens) {
            halt(JudgmentFailure.budgetExceeded);
          }
        } on JudgmentException catch (e) {
          items[index] = JudgmentBatchItem._(null, e.failure, true);
        } catch (_) {
          // Stop siblings on programming/adapter errors and preserve the error.
          halt(JudgmentFailure.cancelled);
          rethrow;
        } finally {
          inFlight--;
          final completed = settled;
          settled = Completer<void>();
          completed.complete();
          callTimer.cancel();
          detach();
        }
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < limits.concurrency && i < work.length; i++) worker()
      ]);
      return JudgmentBatchResult._(
          List.unmodifiable(items.cast<JudgmentBatchItem>()), charged);
    } finally {
      timer.cancel();
      unsubscribe?.call();
      _running = false;
    }
  }
}
