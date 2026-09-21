import 'models.dart';

/// One batch of independent judgments over the same immutable state.
/// Orchestrators own dependent stages, concurrency, retries, and action policy.
abstract interface class JudgmentService {
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  });
}

/// Reusable across a group of evaluations; listeners detach after settlement.
class JudgmentCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// Returns an unsubscribe callback. Already-cancelled tokens notify inline.
  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

enum JudgmentFailure {
  authentication,
  permission,
  invalidRequest,
  rateLimited,
  unavailable,
  http,
  transport,
  timeout,
  cancelled,
  closed,
  invalidResponse,
  responseTooLarge,
  requestTooLarge,
  budgetExceeded,
}

/// Safe diagnostics: never carries request state, credentials, or raw bodies.
class JudgmentException implements Exception {
  final JudgmentFailure failure;
  final int? statusCode;
  final Duration? retryAfter;

  const JudgmentException(this.failure, {this.statusCode, this.retryAfter});

  /// A hint for a caller's bounded retry policy, not an automatic retry.
  bool get isRetryable => const {
        JudgmentFailure.rateLimited,
        JudgmentFailure.unavailable,
        JudgmentFailure.transport,
        JudgmentFailure.timeout,
      }.contains(failure);

  @override
  String toString() => 'JudgmentException: ${failure.name}'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}
