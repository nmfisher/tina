/// The loop-only types of tina_engine_2. Shared value types (messages,
/// tools, tool calls, tool results) come from `tina_core`; these belong to
/// this loop alone. All immutable. Snapshots are copies, never live views.
library;

import 'package:tina_core/tina_core.dart';

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
  final List<ToolSchema> tools;

  /// A deep copy: new list, new tool schemas.
  Request snapshot() => Request(
        systemPrompt: systemPrompt,
        messages: List.of(messages),
        tools: List.of(tools),
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
        messages: List.of(messages),
        modelRequests: [for (final r in modelRequests) r.snapshot()],
        modelResponses: List.of(modelResponses),
        usage: usage,
        detail: detail,
        changedBy: changedBy,
      );

  @override
  String toString() => 'Outcome($stopReason, ${messages.length} messages)';
}

/// The guard decision for one [ToolUse].
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
