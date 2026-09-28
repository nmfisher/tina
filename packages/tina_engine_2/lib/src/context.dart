/// The cancellation path and the turn context every plugin phase runs on.
library;

import 'dart:async';

import 'package:tina_core/tina_core.dart';

import 'model.dart';

/// The one cancellation path. Set once; there is no unset. The loop checks
/// it before every model call and before every tool.
final class CancelToken {
  bool cancelled = false;
  String reason = '';
  final _done = Completer<void>();
  Future<void> get whenCancelled => _done.future;

  /// First cancel wins. Later calls change nothing.
  void cancel(String why) {
    if (cancelled) return;
    cancelled = true;
    reason = why;
    _done.complete();
  }
}

/// The state of one turn in progress, handed to every plugin phase. Plain
/// mutable fields — a plugin reads what it needs and assigns what it wants
/// to change. No builder, no fluent helpers.
///
/// The loop never hands a plugin the live context. It copies before every
/// plugin call, hands the copy over, and keeps the copy the call wrote: a
/// plugin that throws has its copy discarded, so its writes drop and the
/// turn continues, and the next plugin is handed a copy of the *current*
/// state, so it sees what the plugins before it did. The loop therefore
/// holds the before and the after of every plugin call — recording that
/// detail is a later slice.
final class TurnContext {
  TurnContext(
    this._cancel, {
    required this.input,
    required List<Message> messages,
    required List<String> promptSections,
    required List<ToolSchema> pinnedTools,
    this.call,
    this.toolResult,
    this.decision = const Decision.allow(),
    this.outcome,
  })  : messages = messages,
        promptSections = promptSections,
        pinnedTools = pinnedTools;

  final CancelToken _cancel;

  /// Mark the turn cancelled. First call wins.
  void cancel(String why) => _cancel.cancel(why);

  /// Whether the turn has been cancelled.
  bool get cancelled => _cancel.cancelled;

  /// Completes when this turn is cancelled, so pending plugin work can stop.
  Future<void> get whenCancelled => _cancel.whenCancelled;

  /// Why, when [cancelled].
  String get cancelReason => _cancel.reason;

  /// The user input for this turn. A rewrite is an assignment.
  Input input;

  /// The messages so far — what the model would see if called now.
  List<Message> messages;

  /// The prompt sections so far, in the order they were added. The loop
  /// owns the join; a plugin adds one section, never a whole prompt.
  List<String> promptSections;

  /// The pinned tool schemas.
  List<ToolSchema> pinnedTools;

  /// The tool call in flight, when the phase is about a tool call.
  ToolUse? call;

  /// The tool result, when the phase is after a tool ran.
  ToolResult? toolResult;

  /// The decision for [call], when the phase is a guard.
  Decision decision;

  /// The outcome, at the end of the turn.
  Outcome? outcome;

  /// The copy the loop hands a plugin: new lists, same elements. Writes to
  /// a copy are invisible to the turn until the loop keeps that copy.
  TurnContext copy() => TurnContext(
        _cancel,
        input: input,
        messages: List.of(messages),
        promptSections: List.of(promptSections),
        pinnedTools: List.of(pinnedTools),
        call: call,
        toolResult: toolResult,
        decision: decision,
        outcome: outcome,
      );
}
