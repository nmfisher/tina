import 'dart:async';

import '../tools/tool.dart';
import 'message.dart';
import 'provider.dart';

/// One logical model served by N equivalent member providers, round-robin.
///
/// Hosted endpoints rate-limit per API key — a key maps to one provider
/// here — so a session pinned to one provider inherits that provider's
/// ceiling (NVIDIA NIM 429s at 40 req/min per key in the wild) and nothing
/// can go above it, even when the same model is served by several
/// providers. A pool multiplies the ceiling: three members capped at 40
/// req/min each rotate to ~120 req/min aggregate, each member still spaced
/// by its own [RateLimitedProvider] beneath this decorator.
///
/// Routing and failure semantics:
/// * sends rotate strictly across members (request i goes to the member
///   after the one that served request i-1, skipping cooling members);
/// * a member whose stream fails BEFORE any content — a 429, a 5xx, a bad
///   key, anything — is marked cooling for [cooldown] and the SAME send
///   immediately retries on the next member, at most one pass per send;
/// * every member failing before content re-emits the LAST error, the
///   shape callers already understand from a single provider;
/// * an error AFTER content has streamed surfaces as-is — failing over
///   mid-stream would duplicate the partial content (the same rule
///   [RetryingProvider] applies to its own re-attempts);
/// * a send that finds every member still cooling (e.g. an immediate
///   re-send after a total failure) surfaces a cooling error rather than
///   hammering a member that just failed — the policy retry above
///   re-enters the pool after its backoff, by which time the earliest
///   member has usually recovered.
///
/// Composed beneath the metering/retry decorators in [ProviderRegistry],
/// a policy-layer retry re-enters `send` and naturally lands on the NEXT
/// member — the pool is one more rotation, not a bypass of it.
///
/// Like [RetryingProvider], the stream is controller-backed so cancelling
/// while a member is mid-stream tears down promptly via the inner
/// subscription.
class PooledProvider implements LlmProvider {
  /// The equivalent providers this pool rotates across. Order is the
  /// rotation order. Members are pre-built (limiter-decorated) providers —
  /// the pool has no registry knowledge of its own.
  final List<LlmProvider> members;

  /// How long a member that failed before content is skipped for. Zero
  /// disables skipping: rotation is then pure round-robin and only the
  /// within-send failover pass applies.
  final Duration cooldown;

  /// Monotonic clock (see [ProviderRateLimiter] for why not DateTime.now).
  final Stopwatch _clock = Stopwatch()..start();

  /// Index the next send starts rotating from.
  int _next = 0;

  /// Per member: earliest time it may serve again. Absent = eligible.
  final Map<LlmProvider, Duration> _coolingUntil = {};

  PooledProvider(this.members, {this.cooldown = const Duration(seconds: 5)})
      : assert(members.isNotEmpty, 'a pool needs at least one member');

  /// The pool speaks with one voice: `/model <name>` (which assigns
  /// `provider.model = next`) must reach EVERY member or they stop being
  /// equivalent after a swap.
  @override
  String get model => members.first.model;
  @override
  set model(String value) {
    for (final m in members) {
      m.model = value;
    }
  }

  @override
  void close() {
    for (final m in members) {
      m.close();
    }
  }

  /// Whether [member]'s cooldown (if any) has elapsed.
  bool _isEligible(LlmProvider member) {
    final until = _coolingUntil[member];
    return until == null || _clock.elapsed >= until;
  }

  /// The next eligible member, or null when every member is cooling.
  /// Advances the rotation past the member it hands out.
  LlmProvider? _takeMember() {
    for (var i = 0; i < members.length; i++) {
      final index = (_next + i) % members.length;
      final member = members[index];
      if (!_isEligible(member)) continue;
      _next = (index + 1) % members.length;
      return member;
    }
    return null;
  }

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    late StreamController<StreamEvent> controller;
    final cancelled = Completer<void>();
    // The member stream currently on the wire; cancelled from the
    // controller's onCancel so a downstream cancel aborts it too.
    StreamSubscription<StreamEvent>? activeSub;

    /// Pump one member's stream to [controller]. Returns the swallowed
    /// before-content error when this member failed and a failover is
    /// warranted (the caller cools it down and tries the next); null when
    /// the attempt ran to its terminal event (or was cancelled).
    Future<StreamError?> _attempt(LlmProvider member) {
      final done = Completer<void>();
      StreamError? swallowed;
      var forwarded = false;
      late final StreamSubscription<StreamEvent> sub;
      sub = member
          .send(system: system, messages: messages, tools: tools)
          .listen(
            (event) {
              // Cancelled or already swallowed: drop the rest — a
              // failover (or teardown) supersedes this attempt.
              if (cancelled.isCompleted || swallowed != null) return;
              if (!forwarded && event is StreamError) {
                swallowed = event;
                return;
              }
              forwarded = true;
              if (!controller.isClosed) controller.add(event);
            },
            onError: (Object e, StackTrace st) {
              // Transport-channel errors (providers normally fold these
              // into [StreamError] events) forward like content: failover
              // only reacts to before-content StreamErrors, mirroring
              // [RetryingProvider].
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
      StreamError? lastError;
      for (var tried = 0; tried < members.length; tried++) {
        final member = _takeMember();
        // Everyone cooling: surface it rather than hammering a member
        // that just failed (see the class doc).
        if (member == null) break;
        final failure = await _attempt(member);
        if (cancelled.isCompleted) return;
        if (failure == null) {
          // Terminal attempt — its events (including any error that
          // surfaced after content) were forwarded. Close the send.
          if (!controller.isClosed) controller.close();
          return;
        }
        lastError = failure;
        if (cooldown > Duration.zero) {
          _coolingUntil[member] = _clock.elapsed + cooldown;
        }
      }
      if (!controller.isClosed) {
        controller.add(lastError ??
            const StreamError(
                'pooled provider: every member is cooling down after a '
                'failure'));
        controller.close();
      }
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
}
