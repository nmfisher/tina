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
/// plugin whose phase fails has its copy discarded, so its *context*
/// writes are dropped, and the next plugin is handed a copy of the
/// *current* state, so it sees what the plugins before it did. What a
/// dropped copy does **not** undo:
///
/// - the cancellation token is shared by every copy and the live context —
///   a cancel is a turn-wide fact and is never rolled back;
/// - the copy is shallow at the payload boundary: the lists are new but
///   the `Message`, block and `ToolSchema` elements are shared references.
///   Payload objects are immutable by convention; a plugin that mutates a
///   payload in place affects the turn whether its copy is kept or not.
///
/// A phase failure also sets [hookFailure], so the failing phase's copy
/// can carry its own diagnostic even when the loop discards its writes.
/// The loop therefore holds the before and the after of every plugin call
/// — recording that detail is a later slice.
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
    this.hookFailure,
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

  /// The phase failure this context's phase produced, when one did. Set by
  /// the loop, not the plugin: the diagnostic is the engine's structured
  /// report of a failed hook, kept off prompts and tool results.
  HookFailure? hookFailure;

  /// The accepted stop request, when one was made. Set by [requestStop];
  /// first stop wins. Present even on copies the loop later discards —
  /// stopping is turn-wide, like cancellation.
  StopRequest? _stopRequest;
  StopRequest? get stopRequest => _stopRequest;

  /// A plugin asks the turn to stop. One generic stop, first request wins
  /// (later requests are no-ops), attributed to the invoking plugin by its
  /// id — the same id every entry the plugin causes carries. The turn ends
  /// at the loop's next stop check; the request is persisted in the turn's
  /// `turn_ended` entry.
  ///
  /// Interrupts pending work like cancellation, with structured attribution.
  /// The engine assigns the invoking plugin ID when accepting the request.
  void requestStop(String code, {String detail = ''}) {
    if (stopRequest != null || _cancel.cancelled) return;
    _stopRequest = StopRequest(pluginId: '', code: code, detail: detail);
    _cancel.cancel('plugin stop: ${stopRequest!}');
  }

  /// The copy the loop hands a plugin: new lists, same elements. Writes to
  /// a copy are invisible to the turn until the loop keeps that copy; the
  /// cancellation token and the payload objects are shared (see the class
  /// doc), and the copy starts with a null [hookFailure] — a fresh phase,
  /// not the previous phase's diagnostic.
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
