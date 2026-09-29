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

  /// A copy, so the input phase can hand the turn a rewritten input.
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

/// A plugin's request to stop the turn: one generic stop, attributed to
/// the plugin that asked, with an optional free-text detail. `code` is
/// deliberately not an enum — plugins define their own vocabulary and the
/// engine must not grow a per-plugin stop reason. The turn ends
/// [StopReason.cancelled] in the log with this request recorded as the
/// termination metadata on the `turn_ended` entry.
final class StopRequest {
  const StopRequest({
    required this.pluginId,
    required this.code,
    this.detail = '',
  });

  /// The plugin that asked to stop.
  final String pluginId;

  /// The plugin's own stop code, e.g. `step_limit`.
  final String code;

  /// Optional human- and model-readable context, e.g. `16 of 16 steps`.
  final String detail;

  Map<String, dynamic> toJson() => {
        'plugin_id': pluginId,
        'code': code,
        if (detail.isNotEmpty) 'detail': detail,
      };

  static StopRequest? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : StopRequest(
          pluginId: j['plugin_id'] as String,
          code: j['code'] as String,
          detail: j['detail'] as String? ?? '',
        );

  @override
  String toString() =>
      detail.isEmpty ? '$pluginId/$code' : '$pluginId/$code: $detail';
}

/// Why an enforcement hook failed. The phase decides the consequence; the
/// reason says the failure was a plugin exception, not a decision.
enum HookFailureReason { threw }

/// The structured diagnostic a phase failure produces: which plugin, in
/// which phase, and a safe one-line message. Exception contents are not
/// copied verbatim by default — a host that wants stacks wires an explicit
/// diagnostic sink and receives the original error object through
/// [HookFailure.error].
final class HookFailure {
  const HookFailure({
    required this.pluginId,
    required this.phase,
    required this.reason,
    required this.message,
    this.error,
  });

  /// The plugin whose hook failed.
  final String pluginId;

  /// The phase that failed, e.g. `beforeToolCall`.
  final String phase;

  /// Why the hook did not produce a decision.
  final HookFailureReason reason;

  /// A safe, single-line summary. The loop builds it from the error's
  /// runtime type — not its full text, which may carry paths or payload
  /// fragments that must not reach a model prompt or the terminal by
  /// default.
  final String message;

  /// The original error, for an explicit diagnostic sink. Never placed in
  /// a prompt or a tool result by the loop.
  final Object? error;

  @override
  String toString() => 'plugin $pluginId failed in $phase ($reason): $message';
}

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
    this.stopRequest,
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

  /// The plugin id whose input-phase write recorded a change, if any.
  final String? changedBy;

  /// The accepted plugin stop request, when a plugin asked the turn to
  /// stop. Null for user cancels, errors and natural completion. The log's
  /// `turn_ended` entry carries the same metadata as a JSON map.
  final StopRequest? stopRequest;

  /// A copy.
  Outcome snapshot() => Outcome(
        stopReason: stopReason,
        messages: List.of(messages),
        modelRequests: [for (final r in modelRequests) r.snapshot()],
        modelResponses: List.of(modelResponses),
        usage: usage,
        detail: detail,
        changedBy: changedBy,
        stopRequest: stopRequest,
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
  const Decision.ask(this.reason, {this.replacement}) : kind = DecisionKind.ask;

  final DecisionKind kind;
  final String reason;

  /// When set on a deny, the loop records this result instead of a bare
  /// denial. Optional; the core writes it either way.
  final ToolResult? replacement;
}
