import 'message.dart';
import '../tools/tool.dart';

class TokenUsage {
  final int inputTokens;
  final int outputTokens;

  /// Tokens that were stored in the prompt cache on this request (counted
  /// at the cache-write rate). Zero for providers without explicit caching.
  final int cacheCreationInputTokens;

  /// Tokens that were read from the prompt cache on this request (counted
  /// at the cheap cache-read rate). Zero on a cache miss or when caching
  /// is unavailable.
  final int cacheReadInputTokens;

  /// #46: true when the numbers here were APPROXIMATED — a failed transport
  /// attempt whose error carried no usage gets the estimated size of the body
  /// it re-sent — rather than reported by the provider. Estimated usage is
  /// booked via [SpendLedger.recordEstimated] into a separate counter and
  /// shown distinctly ("X measured + Y estimated") so it never masquerades as
  /// measured, but it counts toward the same ceilings so a runaway retry
  /// ladder trips them like real spend. Provider-reported usage never sets
  /// this flag (its default is false).
  final bool estimated;

  const TokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    this.cacheCreationInputTokens = 0,
    this.cacheReadInputTokens = 0,
    this.estimated = false,
  });

  static const zero = TokenUsage(inputTokens: 0, outputTokens: 0);

  TokenUsage operator +(TokenUsage other) => TokenUsage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        cacheCreationInputTokens:
            cacheCreationInputTokens + other.cacheCreationInputTokens,
        cacheReadInputTokens: cacheReadInputTokens + other.cacheReadInputTokens,
      );

  bool get isEmpty =>
      inputTokens == 0 &&
      outputTokens == 0 &&
      cacheCreationInputTokens == 0 &&
      cacheReadInputTokens == 0;
}

sealed class StreamEvent {
  const StreamEvent();
}

class TextDelta extends StreamEvent {
  final String text;
  const TextDelta(this.text);
}

/// Raw provider reasoning for local retention, never answer text.
/// Each wire attempt starts a new block, including retries and pool failover.
sealed class ReasoningEvent extends StreamEvent {
  const ReasoningEvent();
}

class ReasoningDelta extends ReasoningEvent {
  final String text;
  final bool startsBlock;
  const ReasoningDelta(this.text, {this.startsBlock = false});
}

class ReasoningEnd extends ReasoningEvent {
  final bool complete;
  const ReasoningEnd({this.complete = true});
}

/// A status notice emitted mid-stream by the policy layer (retry ladders,
/// pool failover): the send is still alive, but the user should see WHY
/// nothing is happening. Rendered by the consumer as a sink notice — never
/// message content, never transcript text.
class StreamNotice extends StreamEvent {
  final String text;
  const StreamNotice(this.text);
}

class ToolCallStart extends StreamEvent {
  final String id;
  final String name;
  const ToolCallStart({required this.id, required this.name});
}

class MessageComplete extends StreamEvent {
  final List<ContentBlock> content;
  final String stopReason;
  final TokenUsage? usage;
  final CompletionDiagnostics? diagnostics;
  const MessageComplete({
    required this.content,
    required this.stopReason,
    this.usage,
    this.diagnostics,
  });
}

/// Observations about generation, separate from answer content and spend.
/// Reasoning tokens are a subset of output usage, never additional spend.
class CompletionDiagnostics {
  final bool reasoningObserved;
  final int? reasoningTokens;
  final int? outputLimit;
  final String? recoveryHint;
  const CompletionDiagnostics({
    this.reasoningObserved = false,
    this.reasoningTokens,
    this.outputLimit,
    this.recoveryHint,
  });
}

/// Why a completed response contains no usable answer or tool call. Only a
/// transient empty response should be retried with the same request.
enum EmptyCompletionCause { transient, outputLimit, filtered, reasoningOnly }

/// Shared by pool failover and agent recovery so neither layer hides a
/// terminal stop reason by treating it as a transient empty response.
EmptyCompletionCause? classifyEmptyCompletion(
    List<ContentBlock> content, String? stopReason,
    {bool reasoningObserved = false}) {
  if (!content
      .every((block) => block is TextBlock && block.text.trim().isEmpty)) {
    return null;
  }
  return switch (stopReason) {
    'length' || 'max_tokens' => EmptyCompletionCause.outputLimit,
    'content_filter' || 'refusal' || 'safety' => EmptyCompletionCause.filtered,
    _ => reasoningObserved
        ? EmptyCompletionCause.reasoningOnly
        : EmptyCompletionCause.transient,
  };
}

class StreamError extends StreamEvent {
  final Object error;

  /// Provider business error metadata, distinct from the HTTP status.
  final String? providerCode;
  final String? providerType;
  final bool _requiresUserAction;

  /// Authentication, billing, exhausted quota, or account restrictions that
  /// cannot recover through this turn's retry ladder. Overrides transient
  /// hints, including HTTP 429; HTTP 401/403 always require user action.
  bool get requiresUserAction =>
      _requiresUserAction || statusCode == 401 || statusCode == 403;

  /// The HTTP status the transport failed with, when the error is a non-200
  /// response (null for connection/parse failures). Carried separately from
  /// the humanized [error] text so wrappers (the rate-limit adapter's
  /// adaptive backoff, the policy-layer retry) can react to e.g. 429s
  /// without string-matching.
  final int? statusCode;

  /// A server-supplied `Retry-After` hint parsed off the failed response.
  /// The policy-layer retry prefers it over its local backoff schedule.
  final Duration? retryAfter;

  /// Whether the cause may clear on its own (a dropped socket, a reset
  /// connection, a header timeout) — folded in by providers from
  /// `isTransientException` so the retry layer can re-attempt without
  /// re-throwing the raw exception through the stream.
  final bool transient;

  /// #46 (a): usage the provider reported IN its error response, when it did.
  /// Several providers include a final usage block in 429/5xx bodies or an
  /// `x-…-tokens` header even when they refuse the request — those tokens were
  /// reported as processed (not a billing receipt). Null when the error carried
  /// none: nothing is invented here. The retry ladder books this measured usage for
  /// the failed attempt INSTEAD of an estimate ([estimated] stays false) —
  /// measured beats estimated for the same attempt.
  final TokenUsage? usage;
  const StreamError(this.error,
      {this.statusCode,
      this.retryAfter,
      this.transient = false,
      this.usage,
      this.providerCode,
      this.providerType,
      bool requiresUserAction = false})
      : _requiresUserAction = requiresUserAction;
}

abstract class LlmProvider {
  /// Mutable so `/model <name>` can switch the active model mid-session.
  String model;
  LlmProvider(this.model);

  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  });

  void close() {}
}
