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

  const TokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    this.cacheCreationInputTokens = 0,
    this.cacheReadInputTokens = 0,
  });

  static const zero = TokenUsage(inputTokens: 0, outputTokens: 0);

  TokenUsage operator +(TokenUsage other) => TokenUsage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        cacheCreationInputTokens:
            cacheCreationInputTokens + other.cacheCreationInputTokens,
        cacheReadInputTokens:
            cacheReadInputTokens + other.cacheReadInputTokens,
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

class ToolCallStart extends StreamEvent {
  final String id;
  final String name;
  const ToolCallStart({required this.id, required this.name});
}

class MessageComplete extends StreamEvent {
  final List<ContentBlock> content;
  final String stopReason;
  final TokenUsage? usage;
  const MessageComplete({
    required this.content,
    required this.stopReason,
    this.usage,
  });
}

class StreamError extends StreamEvent {
  final Object error;
  const StreamError(this.error);
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
