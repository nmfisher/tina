import '../tools/tool.dart';

/// How an agent emits output. The agent says *what happened*; the
/// implementation decides whether and how to render it (the chat panel, a
/// future tool strip, a sub-agent's parent, a silent capture, a log). The
/// agent layer never touches a UI type — this interface imports only the
/// [ToolEvent] payload types.
///
/// One payload ([ToolEvent]) serves three delivery shapes: the sink's tool
/// methods, the tool strip, and the broadcast bus. Denied / unknown tools
/// never reach [toolStart] (no event is emitted for them), matching the
/// agent's pre-existing behavior.
///
/// Delivery is semantic, never pre-formatted: the engine hands over the model's
/// reasoning *text* ([reasoning]) and lets the sink decide what a reader sees,
/// so it owns no display strings for the frontend to import.
enum NoticeKind { info, warning, error }

abstract class AgentSink {
  /// Streamed model prose (assistant text deltas).
  void text(String s);

  /// Terminate the current line of prose.
  void newline();

  /// Streamed model reasoning for the current request. [startsBlock] is true on
  /// the first chunk of a new block (a retried request opens a second one);
  /// [reasoningEnd] closes the block.
  ///
  /// Reasoning is *thinking*, not output: a sink may show it, collapse it to a
  /// count, or ignore it entirely — but it is delivered, so the choice belongs
  /// to the sink rather than to the engine.
  void reasoning(String text, {bool startsBlock = false});

  /// The current reasoning block ended. [complete] is false when the provider
  /// cut the thought off (a failed or cancelled request), so a reader can tell
  /// a finished thought from a truncated one.
  void reasoningEnd({required bool complete});

  /// A tool is about to execute (after permission approval).
  void toolStart(ToolStartEvent event);

  /// Incremental output from a running tool (e.g. bash stdout/stderr).
  void toolOutput(ToolOutputEvent event);

  /// A tool finished — success or failure.
  void toolComplete(ToolCompleteEvent event);

  /// A status line: `[cancelled]`, budget/usage, stream errors, `unknown
  /// tool`, etc.
  void notice(String message, {NoticeKind kind = NoticeKind.info});

  /// "The agent is working" signal. A UI may render a spinner; a sub-agent
  /// ignores it.
  void activityStart();

  /// "The agent stopped producing for now."
  void activityStop();
}
