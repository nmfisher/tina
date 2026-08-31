import 'dart:async';

import '../llm/message.dart';
import '../llm/provider.dart';

import 'agent_sink.dart';

/// Consumes a single provider stream, surfacing the assembled result as a
/// [TurnOutcome]. Extracted from [Agent] so the Completer / subscription /
/// cancellation choreography can be tested in isolation.
///
/// Stateless: all rendering goes through the [AgentSink] passed to [consume],
/// so this class holds no UI references. Usage:
/// ```dart
/// const consumer = ProviderStreamConsumer();
/// final outcome = await consumer.consume(
///   provider.send(system: ..., messages: ..., tools: ...),
///   sink: mySink,
///   cancelSignal: myCompleter.future,
/// );
/// ```
class ProviderStreamConsumer {
  const ProviderStreamConsumer();

  /// Listen to [stream] until it completes, is cancelled, or errors.
  /// Text deltas and tool-call starts are rendered live via [sink]. Returns an
  /// [TurnOutcome] with the assembled content.
  Future<TurnOutcome> consume(
    Stream<StreamEvent> stream, {
    required AgentSink sink,
    Future<void>? cancelSignal,
  }) async {
    sink.activityStart();
    final done = Completer<void>();
    List<ContentBlock>? content;
    TokenUsage? usage;
    Object? error;

    /// The raw [StreamError] behind [error], when the failure arrived as one
    /// (#28). Carries statusCode / transient / retryAfter, which the agent's
    /// turn-level retry ladder needs to classify the failure — the humanized
    /// [error] string alone cannot. Stays null on the subscription `onError`
    /// path (a bare exception below the stream), which remains unclassified.
    StreamError? streamError;
    var cancelled = false;
    var sawTextThisTurn = false;

    late StreamSubscription<StreamEvent> sub;
    sub = stream.listen(
      (event) {
        if (cancelled) return;
        if (event is TextDelta) {
          sink.activityStop();
          sink.text(event.text);
          sawTextThisTurn = true;
        } else if (event is ToolCallStart) {
          sink.activityStop();
          if (sawTextThisTurn) sink.newline();
          sawTextThisTurn = false;
        } else if (event is MessageComplete) {
          content = event.content;
          usage = event.usage;
        } else if (event is StreamError) {
          error = event.error;
          streamError = event;
        }
      },
      onDone: () {
        sink.activityStop();
        if (sawTextThisTurn) sink.newline();
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        sink.activityStop();
        error = e;
        if (!done.isCompleted) done.complete();
      },
    );

    final cancelSub = cancelSignal?.then((_) async {
      cancelled = true;
      sink.activityStop();
      sink.notice('\n[cancelled]\n', kind: NoticeKind.warning);
      await sub.cancel();
      if (!done.isCompleted) done.complete();
    });

    await done.future;
    // Only await the cancel teardown when cancel actually fired. Awaiting
    // unconditionally would deadlock any turn whose [cancelSignal] never
    // completes: callers (e.g. the REPL) pass a non-null cancelSignal that
    // only fires on ESC, so [cancelSub] would otherwise never resolve after a
    // normally-completing stream. When the stream finished on its own, there's
    // no in-flight cancellation to wait for.
    if (cancelled) await cancelSub;

    return TurnOutcome(
      content: content,
      usage: usage,
      error: error,
      streamError: streamError,
      cancelled: cancelled,
    );
  }
}

/// The result of consuming one provider stream.
class TurnOutcome {
  final List<ContentBlock>? content;
  final TokenUsage? usage;
  final Object? error;

  /// The raw [StreamError] when [error] came from one — with the transport
  /// metadata (statusCode / transient / retryAfter) the [error] string alone
  /// discards. Null when the failure arrived via the stream's `onError` path
  /// or there was no failure; consumers classify retryability ONLY through
  /// this (an unclassified error must not be retried).
  final StreamError? streamError;
  final bool cancelled;

  const TurnOutcome({
    this.content,
    this.usage,
    this.error,
    this.streamError,
    required this.cancelled,
  });
}
