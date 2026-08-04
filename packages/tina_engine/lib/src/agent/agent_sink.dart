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
enum NoticeKind { info, warning, error }

abstract class AgentSink {
  /// Streamed model prose (assistant text deltas).
  void text(String s);

  /// Terminate the current line of prose.
  void newline();

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
