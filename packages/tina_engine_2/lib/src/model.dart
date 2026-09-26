/// The value types of tina_engine_2. All immutable. Snapshots are copies,
/// never live views.
library;

/// The kind of a [Message].
enum MessageKind { user, assistant, toolResult }

/// One transcript entry.
final class Message {
  const Message.user(this.text)
      : kind = MessageKind.user,
        toolCalls = const [],
        result = null;

  const Message.assistant(this.text, {this.toolCalls = const []})
      : kind = MessageKind.assistant,
        result = null;

  /// Not const: it reads [ToolResult.content], which is not a constant.
  Message.toolResult(ToolResult result)
      : kind = MessageKind.toolResult,
        text = result.content,
        toolCalls = const [],
        result = result;

  const Message._(this.kind, this.text, this.toolCalls, this.result);

  final MessageKind kind;

  /// The text of a user or assistant message; the content of a tool result.
  final String text;

  /// The tool calls an assistant message asks for, if any.
  final List<ToolCall> toolCalls;

  /// The result carried by a [MessageKind.toolResult] message.
  final ToolResult? result;

  /// A copy. Mutating the source later cannot change this message.
  Message copy() => Message._(kind, text, List.of(toolCalls), result);

  @override
  String toString() => 'Message($kind, $text)';
}

/// A tool the model may call. Name, description, schema. No executor inside.
final class Tool {
  const Tool(this.name, this.description, this.inputSchema);

  final String name;
  final String description;

  /// A JSON-schema-shaped map. Opaque here; providers format it.
  final Map<String, Object?> inputSchema;

  /// A copy with its own schema map.
  Tool snapshot() => Tool(name, description, Map.of(inputSchema));

  @override
  bool operator ==(Object other) => other is Tool && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'Tool($name)';
}

/// A `tool_use` the model asked for: id, name, arguments.
final class ToolCall {
  const ToolCall(this.id, this.name, this.arguments);

  final String id;
  final String name;

  /// Decoded JSON arguments. Opaque here.
  final Map<String, Object?> arguments;

  /// A copy with its own arguments map.
  ToolCall snapshot() => ToolCall(id, name, Map.of(arguments));

  @override
  String toString() => 'ToolCall($id, $name)';
}

/// What a tool produced for one [ToolCall]. Always paired to its call by id.
final class ToolResult {
  const ToolResult({
    required this.callId,
    required this.toolName,
    required this.ok,
    this.content = '',
    this.meta = const {},
  });

  /// The [ToolCall.id] this result is paired to.
  final String callId;
  final String toolName;

  /// Whether the tool ran and succeeded. A denied or skipped call is not ok.
  final bool ok;
  final String content;

  /// Why a call was denied or skipped. Empty when [ok].
  final Map<String, Object?> meta;

  /// A copy with its own maps.
  ToolResult snapshot() => ToolResult(
      callId: callId,
      toolName: toolName,
      ok: ok,
      content: content,
      meta: Map.of(meta));

  @override
  String toString() => 'ToolResult($callId, $toolName, ok: $ok)';
}

/// One user input. Enters the loop and the transcript once, at step 1.
final class Input {
  const Input(this.text, {required this.id});

  final String text;
  final String id;

  /// A copy, so `beforeInvocation` can return a new input.
  Input withText(String newText, {String? newId}) =>
      Input(newText, id: newId ?? id);

  @override
  String toString() => 'Input($id, $text)';
}

/// One model request: system prompt, messages, tools. Immutable by copy.
final class Request {
  const Request({
    required this.systemPrompt,
    required this.messages,
    required this.tools,
  });

  final String systemPrompt;
  final List<Message> messages;
  final List<Tool> tools;

  /// A deep copy: new list, new messages, new tools.
  Request snapshot() => Request(
        systemPrompt: systemPrompt,
        messages: List.of(messages),
        tools: [for (final t in tools) t.snapshot()],
      );

  @override
  String toString() =>
      'Request(${messages.length} messages, ${tools.length} tools)';
}

/// Why a turn stopped.
enum StopReason { complete, cancelled, error }

/// What one turn produced: appended messages, requests, replies, stop reason.
final class Outcome {
  const Outcome({
    required this.stopReason,
    required this.messages,
    required this.modelRequests,
    required this.modelResponses,
    this.usage = 0,
    this.detail = '',
    this.changedBy,
  });

  final StopReason stopReason;

  /// Every message the turn appended, in order. First is the user input.
  final List<Message> messages;
  final List<Request> modelRequests;
  final List<Message> modelResponses;

  /// A stand-in usage count: model responses this turn. No real tokenizer.
  final int usage;

  /// Extra detail: the final answer, a cancellation point, an error string.
  final String detail;

  /// The plugin id whose `beforeInvocation` recorded a change, if any.
  final String? changedBy;

  /// A copy.
  Outcome snapshot() => Outcome(
        stopReason: stopReason,
        messages: [for (final m in messages) m.copy()],
        modelRequests: [for (final r in modelRequests) r.snapshot()],
        modelResponses: [for (final m in modelResponses) m.copy()],
        usage: usage,
        detail: detail,
        changedBy: changedBy,
      );

  @override
  String toString() => 'Outcome($stopReason, ${messages.length} messages)';
}

/// The guard decision for one [ToolCall].
enum DecisionKind { allow, deny, ask }

/// What a guard decided about one tool call.
final class Decision {
  const Decision.allow([this.reason = ''])
      : kind = DecisionKind.allow,
        replacement = null;
  const Decision.deny(this.reason, {this.replacement})
      : kind = DecisionKind.deny;
  const Decision.ask(this.reason, {this.replacement})
      : kind = DecisionKind.ask;

  final DecisionKind kind;
  final String reason;

  /// When set on a deny, the loop records this result instead of a bare
  /// denial. Optional; the core writes it either way.
  final ToolResult? replacement;
}
