/// Messages and content blocks, copied verbatim from
/// `packages/tina_engine/lib/src/llm/message.dart` — same names, same members,
/// same JSON keys. The helper functions that operate on transcripts come along
/// because they are part of the type's contract.
library;

/// Who authored a message.
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

  factory ReasoningBlock.fromJson(Map<String, dynamic> json) =>
      ReasoningBlock(json['text'] as String,
          complete: json['complete'] as bool? ?? true);
}

class Message {
  final Role role;
  final List<ContentBlock> content;
  final List<ReasoningBlock> reasoning;

  /// True when this user-role message was composed by the SYSTEM (budget
  /// notices, mode announcements, compaction summaries) rather than typed by
  /// the operator. Both travel as user-role text — that is what the model
  /// must see — but only operator prompts belong in the input editor's ↑/↓
  /// recall history (tin-hist: "Runtime permission mode: ..." used to resurface
  /// in the text field when the user pressed up arrow). Defaults to false so
  /// plain user messages need no change; nothing else keys off it.
  final bool isSynthetic;

  const Message({
    required this.role,
    required this.content,
    this.reasoning = const [],
    this.isSynthetic = false,
  });

  /// A transcript entry that must never become an empty API message.
  bool get isReasoningOnly => content.isEmpty && reasoning.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content.map((b) => b.toJson()).toList(),
        if (reasoning.isNotEmpty)
          'reasoning': reasoning.map((b) => b.toJson()).toList(),
        if (isSynthetic) 'synthetic': true,
      };

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        role: Role.values.byName(j['role'] as String),
        content: (j['content'] as List)
            .map((b) =>
                ContentBlock.fromJson(Map<String, dynamic>.from(b as Map)))
            .toList(),
        reasoning: (j['reasoning'] as List? ?? const [])
            .map((b) =>
                ReasoningBlock.fromJson(Map<String, dynamic>.from(b as Map)))
            .toList(),
        // Absent on legacy journal lines: old sessions had no synthetic
        // marker, and restoring one must not erase typed prompts from recall.
        isSynthetic: j['synthetic'] as bool? ?? false,
      );
}

/// Journal writes save tool results individually, while provider history keeps
/// all results of an assistant's batch in one user message.
List<Message> coalesceToolResults(List<Message> messages) {
  bool isResults(Message m) =>
      m.role == Role.user &&
      m.reasoning.isEmpty &&
      m.content.isNotEmpty &&
      m.content.every((b) => b is ToolResultBlock);
  final out = <Message>[];
  for (final m in messages) {
    if (out.isNotEmpty && isResults(out.last) && isResults(m)) {
      out[out.length - 1] = Message(
          role: Role.user, content: [...out.last.content, ...m.content]);
    } else {
      out.add(m);
    }
  }
  return out;
}

/// A stopped process may have executed a call without saving its result. Fill
/// missing results before the next user turn so providers receive valid tool
/// exchanges, without claiming the command failed or automatically replaying it.
bool recoverInterruptedToolCalls(List<Message> history) {
  var changed = false;
  for (var i = 0; i < history.length; i++) {
    final m = history[i];
    if (m.role != Role.assistant) continue;
    final calls = m.content.whereType<ToolUseBlock>().toList();
    if (calls.isEmpty) continue;
    final next = i + 1 < history.length ? history[i + 1] : null;
    final hasResults = next != null &&
        next.role == Role.user &&
        next.content.isNotEmpty &&
        next.content.every((b) => b is ToolResultBlock);
    final results = hasResults ? next.content : const <ContentBlock>[];
    final ids =
        results.whereType<ToolResultBlock>().map((b) => b.toolUseId).toSet();
    final missing = calls.where((call) => !ids.contains(call.id)).toList();
    if (missing.isEmpty) continue;
    final repaired = Message(role: Role.user, content: [
      ...results,
      for (final call in missing)
        ToolResultBlock(
            toolUseId: call.id,
            isError: true,
            content: 'No result was recorded before this turn stopped. '
                'Execution status is unknown; this call may have changed files '
                'or external state. Check its effects before considering a retry.'),
    ]);
    if (hasResults) {
      history[i + 1] = repaired;
    } else {
      history.insert(i + 1, repaired);
    }
    changed = true;
  }
  return changed;
}
