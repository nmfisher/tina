import 'package:tina_console/tina_console.dart';

import 'package:tina_engine/tina_engine.dart';

/// The interactive [AgentSink]: routes agent output to the chat panel (and,
/// nominally, the spinner — which is a retired no-op today). This is the only
/// [AgentSink] implementation that imports `tina_console`; it reproduces the
/// agent's historical chat output, so the main chat is visually unchanged.
///
/// When the tool strip lands, the host layer will swap this for a composing
/// sink that routes tool events to the strip and skips them on chat while
/// leaving text/notices on chat. The agent is oblivious to which sink it has.
class ChatAgentSink implements AgentSink {
  final ScrollingTextRegion chat;
  final Spinner spinner;

  ChatAgentSink(this.chat, this.spinner);

  @override
  void text(String s) {
    // The policy layer only picks the style code; the surface owns the
    // passthrough/color/detached fallback (inside [ScrollingTextRegion.appendStyled]).
    chat.beginStyle(chat.screen.theme.chat.agentText);
    chat.appendStyled(s); // stays open across stream chunks; closed by next plain write
  }

  @override
  void newline() => chat.newline();

  @override
  void toolStart(ToolStartEvent e) =>
      chat.dim('→ ${_describe(e.toolName, e.input)}\n');

  @override
  void toolOutput(ToolOutputEvent e) =>
      e.stderr ? chat.red(e.chunk) : chat.dim(e.chunk);

  @override
  void toolComplete(ToolCompleteEvent e) {
    if (e.isError) {
      chat.red('  failed: ${_truncate(e.result, 200)}\n');
    } else {
      chat.dim('  ok\n');
    }
  }

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {
    switch (kind) {
      case NoticeKind.info:
        chat.dim(message);
      case NoticeKind.warning:
        chat.yellow(message);
      case NoticeKind.error:
        chat.red(message);
    }
  }

  @override
  void activityStart() => spinner.start();

  @override
  void activityStop() => spinner.stop();

  // --- description / truncation helpers (moved from agent.dart) ---

  String _describe(String name, Map<String, dynamic> input) {
    switch (name) {
      case 'bash':
        final cmd = input['command'] as String?;
        return cmd != null ? 'bash: ${_truncate(cmd, 80)}' : name;
      case 'read':
      case 'write':
      case 'edit':
        final path = input['filePath'] as String?;
        return path != null ? '$name: $path' : name;
      default:
        return name;
    }
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}
