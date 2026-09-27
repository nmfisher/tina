/// tina's terminal views, layered on `tina_console` (the generic toolkit)
/// and `tina_core` (the value types). Nothing here opens a terminal: every
/// type is a pure value-to-rows rendering or a state holder fed by events,
/// testable headless.
///
/// Layering (see README.md):
/// `dart_notcurses → tina_console → tina_tui → bin/tina.dart`.
///
/// - [ChatView]: a settled `tina_core.Message` to chip rows.
/// - [StreamView]: accumulates `StreamEvent`s into the same rows live.
/// - [ToolChipView] / [toolChipRows]: one tool call + result as one line.
/// - [statusStripRows]: a small status value to strip rows, layout swappable.
/// - [ApprovalDialog]: a pending [ToolUse] plus a key source to a decision.
/// - [DialogApprover]: the same dialog answering the sandbox's `Approver`
///   questions — vocabulary adapter, fail-closed both sides; queueing in
///   [QueuedDialogAsker].
library;

export 'src/chat_view.dart';
export 'src/stream_view.dart';
export 'src/tool_chip_view.dart';
export 'src/status_strip.dart';
export 'src/approval_dialog.dart';
export 'src/approval_approver.dart';
