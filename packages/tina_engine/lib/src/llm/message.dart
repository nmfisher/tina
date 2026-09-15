enum Role { user, assistant }

sealed class ContentBlock {
  const ContentBlock();

  /// Anthropic-shaped JSON. The wire format already covers our three
  /// block types, so persisted sessions stay legible by hand.
  Map<String, dynamic> toJson();

  static ContentBlock fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String?;
    switch (type) {
      case 'text':
        return TextBlock(j['text'] as String);
      case 'tool_use':
        return ToolUseBlock(
          id: j['id'] as String,
          name: j['name'] as String,
          input: Map<String, dynamic>.from(j['input'] as Map),
          argumentsParseError: j['arguments_parse_error'] as String?,
        );
      case 'tool_result':
        return ToolResultBlock(
          toolUseId: j['tool_use_id'] as String,
          content: j['content'] as String,
          isError: (j['is_error'] as bool?) ?? false,
        );
      default:
        throw FormatException('Unknown content block type: $type');
    }
  }
}

class TextBlock extends ContentBlock {
  final String text;
  const TextBlock(this.text);

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ToolUseBlock extends ContentBlock {
  final String id;
  final String name;
  final Map<String, dynamic> input;

  /// Set when the model's tool-call arguments were not valid JSON (tin-p2sq:
  /// a quote-heavy shell one-liner the model failed to escape). [input] is
  /// then empty; the agent turns this into an error tool result so the model
  /// can re-emit the call with correct escaping instead of losing the turn.
  final String? argumentsParseError;
  const ToolUseBlock({
    required this.id,
    required this.name,
    required this.input,
    this.argumentsParseError,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': input,
        if (argumentsParseError != null)
          'arguments_parse_error': argumentsParseError,
      };
}

class ToolResultBlock extends ContentBlock {
  final String toolUseId;
  final String content;
  final bool isError;
  const ToolResultBlock({
    required this.toolUseId,
    required this.content,
    this.isError = false,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_result',
        'tool_use_id': toolUseId,
        'content': content,
        if (isError) 'is_error': true,
      };
}

/// Local transcript data, deliberately separate from model-visible content.
/// Keeping the text here lets a future transcript UI expand the collapsed row.
class ReasoningBlock {
  final String text;
  final bool complete;
  const ReasoningBlock(this.text, {this.complete = true});

  Map<String, dynamic> toJson() => {'text': text, 'complete': complete};

  factory ReasoningBlock.fromJson(Map<String, dynamic> json) => ReasoningBlock(
      json['text'] as String, complete: json['complete'] as bool? ?? true);
}

class Message {
  final Role role;
  final List<ContentBlock> content;
  final List<ReasoningBlock> reasoning;
  const Message({
    required this.role,
    required this.content,
    this.reasoning = const [],
  });

  /// A transcript entry that must never become an empty API message.
  bool get isReasoningOnly => content.isEmpty && reasoning.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content.map((b) => b.toJson()).toList(),
        if (reasoning.isNotEmpty)
          'reasoning': reasoning.map((b) => b.toJson()).toList(),
      };

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        role: Role.values.byName(j['role'] as String),
        content: (j['content'] as List)
            .map((b) =>
                ContentBlock.fromJson(Map<String, dynamic>.from(b as Map)))
            .toList(),
        reasoning: (j['reasoning'] as List? ?? const [])
            .map((b) => ReasoningBlock.fromJson(
                Map<String, dynamic>.from(b as Map)))
            .toList(),
      );
}
