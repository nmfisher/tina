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
  /// [onCancelled] notifies the turn owner immediately, before stream cleanup.
  /// The owner decides how to present cancellation; this consumer does not
  /// emit a turn-level cancellation notice.
  Future<TurnOutcome> consume(
    Stream<StreamEvent> stream, {
    required AgentSink sink,
    Future<void>? cancelSignal,
    void Function()? onCancelled,
  }) async {
    sink.activityStart();
    final done = Completer<void>();
    List<ContentBlock>? content;
    TokenUsage? usage;
    String? stopReason;
    CompletionDiagnostics? diagnostics;
    Object? error;
    final reasoningBuffers = <StringBuffer>[];
    final reasoningComplete = <bool>[];

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
        if (done.isCompleted) return;
        if (event is TextDelta) {
          sink.activityStop();
          sink.text(event.text);
          sawTextThisTurn = true;
        } else if (event is ReasoningDelta) {
          if (event.text.isEmpty) return;
          if (event.startsBlock || reasoningBuffers.isEmpty) {
            reasoningBuffers.add(StringBuffer());
            reasoningComplete.add(false);
            sink.notice('\n${kReasoningCollapsedLabel}\n');
          }
          reasoningBuffers.last.write(event.text);
        } else if (event is ReasoningEnd) {
          if (reasoningComplete.isNotEmpty) {
            reasoningComplete[reasoningComplete.length - 1] = event.complete;
          }
        } else if (event is StreamNotice) {
          sink.notice('\n${event.text}\n', kind: NoticeKind.warning);
        } else if (event is ToolCallStart) {
          sink.activityStop();
          if (sawTextThisTurn) sink.newline();
          sawTextThisTurn = false;
        } else if (event is MessageComplete) {
          content = event.content;
          usage = event.usage;
          stopReason = event.stopReason;
          diagnostics = event.diagnostics;
        } else if (event is StreamError) {
          error = event.error;
          streamError = event;
        }
      },
      onDone: () {
        if (done.isCompleted) return;
        sink.activityStop();
        if (sawTextThisTurn) sink.newline();
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        if (done.isCompleted) return;
        sink.activityStop();
        error = e;
        if (!done.isCompleted) done.complete();
      },
    );

    cancelSignal?.then((_) {
      // A turn reuses its cancellation signal across requests. Futures cannot
      // unsubscribe callbacks, so a settled request must make this a no-op.
      if (done.isCompleted) return;
      cancelled = true;
      sink.activityStop();
      done.complete();
      onCancelled?.call();
    });

    await done.future;
    // Release the subscription on every terminal path, including onError.
    // Never await the turn's cancellation future: it may never complete.
    await sub.cancel();

    return TurnOutcome(
      reasoning: [
        for (var i = 0; i < reasoningBuffers.length; i++)
          ReasoningBlock(reasoningBuffers[i].toString(),
              complete: reasoningComplete[i]),
      ],
      content: content,
      usage: usage,
      stopReason: stopReason,
      diagnostics: diagnostics,
      error: error,
      streamError: streamError,
      cancelled: cancelled,
    );
  }
}

/// The result of consuming one provider stream.
class TurnOutcome {
  final List<ReasoningBlock> reasoning;
  final List<ContentBlock>? content;
  final TokenUsage? usage;

  /// Provider finish reason, retained for empty-response recovery decisions.
  final String? stopReason;
  final CompletionDiagnostics? diagnostics;
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
    this.reasoning = const [],
    this.usage,
    this.stopReason,
    this.diagnostics,
    this.error,
    this.streamError,
    required this.cancelled,
  });
}
