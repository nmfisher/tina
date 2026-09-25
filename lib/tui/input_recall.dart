import 'package:tina_engine/tina_engine.dart';

/// The operator prompts a loaded conversation contributes to the input
/// editor's ↑/↓ recall history (tin-hist).
///
/// Only messages the OPERATOR typed belong in recall. The engine composes
/// user-role messages of its own — the 90% budget nudge, the permission-mode
/// announcement, the post-compaction summary — and marks them
/// [Message.isSynthetic]. Those must keep reaching the model verbatim, but
/// they must never resurface in the text field when the user presses up
/// arrow, so they are filtered out here.
///
/// Blank results (a user-role message with no text blocks — a tool-result
/// batch, say) are passed through as empty strings: [restoreHistory]'s
/// `addHistory` already ignores blank lines, keeping this a pure projection.
List<String> recallHistoryLines(Iterable<Message> history) => [
  for (final message in history)
    if (message.role == Role.user && !message.isSynthetic)
      message.content
          .whereType<TextBlock>()
          .map((block) => block.text)
          .join('\n'),
];
