import 'dart:async';

import '../tools/tool.dart';
import 'http.dart' show applyBackoffJitter, isRetryableStatus, retryDelays;
import 'message.dart';
import 'provider.dart';
import 'wire.dart';

/// Policy-layer retry for LLM sends: re-attempts a request whose FIRST event
/// is a retryable failure (a 408/425/429/5xx [StreamError], or a transient
/// connection failure) instead of surfacing it.
///
/// This is the retry that used to live inside `sendWithRetry` (http.dart) —
/// hoisted above the provider so a retry RE-ENTERS the policy stack: composed
/// outermost in [ProviderRegistry.build], each re-attempt flows back through
/// the metering decorator and the rate limiter, acquiring a fresh launch slot
/// instead of bypassing the queue the way a transport-internal retry would.
/// A 429 therefore lands after the limiter's adaptive backoff widened the
/// queue, not on top of it.
///
/// Retry semantics match the old transport loop:
/// * only failures BEFORE any content streamed — once a delta reached the
///   consumer, re-sending would duplicate it, so the error surfaces;
/// * a server `Retry-After` hint (parsed onto [StreamError.retryAfter])
///   overrides the local [retryDelays] + jitter schedule;
/// * [maxRetries] bounds the total (registry default off; the app sets 3,
///   the historical transport count).
///
/// Like [RateLimitedProvider], the stream is controller-backed so cancelling
/// while parked on a backoff delay tears down promptly and never subscribes
/// the next attempt.
class RetryingProvider implements LlmProvider {
  final LlmProvider inner;
  final int maxRetries;

  RetryingProvider(this.inner, {this.maxRetries = 3});

  /// Delegate so `/model <name>` reaches the real underlying provider.
  @override
  String get model => inner.model;
  @override
  set model(String value) {
    inner.model = value;
  }

  @override
  void close() => inner.close();

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    if (maxRetries <= 0) {
      return inner.send(system: system, messages: messages, tools: tools);
    }
    late StreamController<StreamEvent> controller;
    final cancelled = Completer<void>();
    // The attempt currently on the wire; cancelled from the controller's
    // onCancel so a downstream cancel aborts an in-flight attempt too.
    StreamSubscription<StreamEvent>? activeSub;

    /// Stream one inner attempt, forwarding its events to [controller].
    /// Returns the swallowed retryable error when the attempt failed before
    /// any content and retries remain (the caller backs off and re-sends);
    /// null when the attempt ran to its terminal event (or was cancelled).
    Future<StreamError?> _runAttempt(
      StreamController<StreamEvent> controller,
      Completer<void> cancelled, {
      required String system,
      required List<Message> messages,
      required List<ToolSchema> tools,
      required int retriesLeft,
    }) {
      final done = Completer<void>();
      StreamError? swallowed;
      var forwarded = false;
      late final StreamSubscription<StreamEvent> sub;
      sub = inner
          .send(system: system, messages: messages, tools: tools)
          .listen(
            (event) {
              // Cancelled or already swallowed: drop the rest of this
              // attempt — a retry (or teardown) supersedes it.
              if (cancelled.isCompleted || swallowed != null) return;
              if (!forwarded &&
                  event is StreamError &&
                  retriesLeft > 0 &&
                  _isRetryable(event)) {
                swallowed = event;
                return;
              }
              forwarded = true;
              if (!controller.isClosed) controller.add(event);
            },
            onError: (Object e, StackTrace st) {
              if (cancelled.isCompleted || swallowed != null) return;
              forwarded = true;
              if (!controller.isClosed) controller.addError(e, st);
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
          );
      activeSub = sub;
      return done.future.then((_) async {
        await sub.cancel();
        return swallowed;
      });
    }

    Future<void> run() async {
      for (var attempt = 0; attempt <= maxRetries; attempt++) {
        Wire.report('attempt_start', attempt: attempt + 1, inFlight: true);
        final retryOf = await _runAttempt(
          controller,
          cancelled,
          system: system,
          messages: messages,
          tools: tools,
          retriesLeft: maxRetries - attempt,
        );
        Wire.report('attempt_end', attempt: attempt + 1, inFlight: false);
        if (retryOf == null || cancelled.isCompleted) {
          // Terminal attempt (its events — including any surfaced error —
          // were forwarded): close the send's stream.
          if (!controller.isClosed) controller.close();
          return;
        }
        final delay = retryOf.retryAfter ??
            applyBackoffJitter(
                retryDelays[attempt.clamp(0, retryDelays.length - 1)]);
        Wire.report('backoff', attempt: attempt + 1, inFlight: false);
        // Park on the backoff; a cancel during it ends the send quietly.
        await Future.any([Future<void>.delayed(delay), cancelled.future]);
        if (cancelled.isCompleted) return;
      }
      if (!controller.isClosed) controller.close();
    }

    controller = StreamController<StreamEvent>(
      onListen: () => unawaited(run()),
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
        return activeSub?.cancel();
      },
    );
    return controller.stream;
  }

  static bool _isRetryable(StreamError e) =>
      e.transient || (e.statusCode != null && isRetryableStatus(e.statusCode!));
}
