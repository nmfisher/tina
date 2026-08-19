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
  // Whether anything has been rendered yet — the first message starts at the
  // top of the chat with no leading blank line.
  var drew = false;
  for (final message in history) {
    switch (message.role) {
      case Role.user:
        for (final block in message.content) {
          switch (block) {
            case TextBlock():
              // Blank line between the previous bot message and this user
              // message; the separator below covers the user→bot gap — the
              // same spacing a live turn gets in _runTurn.
              if (drew) host.showSeparator();
              drew = true;
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
                drew = true;
              }
            case ToolUseBlock():
              drew = true;
              host.toolStart(
                  ToolStartEvent(block.name, block.id, block.input));
              host.toolComplete(ToolCompleteEvent(
                  block.name, block.id, isError: false, result: ''));
            default:
              break;
          }
        }
    }
  }
}
