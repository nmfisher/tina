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
  const ToolUseBlock({
    required this.id,
    required this.name,
    required this.input,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': input,
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

class Message {
  final Role role;
  final List<ContentBlock> content;
  const Message({required this.role, required this.content});

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content.map((b) => b.toJson()).toList(),
      };

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        role: Role.values.byName(j['role'] as String),
        content: (j['content'] as List)
            .map((b) =>
                ContentBlock.fromJson(Map<String, dynamic>.from(b as Map)))
            .toList(),
      );
}
