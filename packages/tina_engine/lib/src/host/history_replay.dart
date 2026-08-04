import '../llm/message.dart';
import '../tools/tool.dart';
import 'host_interface.dart';

/// Replay a loaded conversation history into [host]'s chat region. Renders
/// each message the same way a live turn does: user text as a user bar, agent
/// text as agent prose, tool calls as dim indicators. Tool results are
/// summarized (not replayed verbatim) to avoid flooding the chat with large
/// tool output from a prior session.
///
/// Called on startup (`--continue` / `--resume`) and after the in-TUI
/// `/resume` command loads a session's history.
void replayHistory(HostInterface host, List<Message> history) {
  for (final message in history) {
    switch (message.role) {
      case Role.user:
        for (final block in message.content) {
          switch (block) {
            case TextBlock():
              host.showMessage('${block.text}\n',
                  style: HostMessageStyle.user);
              host.showSeparator();
            case ToolResultBlock():
              // Skip tool results — they're often large and the preceding
              // tool_use line already shows what was called.
              break;
            default:
              break;
          }
        }
      case Role.assistant:
        for (final block in message.content) {
          switch (block) {
            case TextBlock():
              if (block.text.isNotEmpty) {
                host.text(block.text);
                host.newline();
              }
            case ToolUseBlock():
              host.toolStart(
                  ToolStartEvent(block.name, block.id, block.input));
              host.toolComplete(ToolCompleteEvent(
                  block.name, block.id, isError: false, result: ''));
            default:
              break;
          }
        }
    }
    // Blank line between consecutive messages for readability.
    host.newline();
  }
}
