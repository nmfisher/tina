import 'package:tina_console/tina_console.dart';

import 'package:tina_engine/tina_engine.dart';

/// A tool call whose streamed output was capped in the chat. The full text is
/// preserved here for the `/output` viewer; the chat shows only the first
/// [ChatAgentSink.displayCap] chars.
class CappedToolOutput {
  final String toolName;
  final Map<String, dynamic> input;
  final String text;

  /// Chars of [text] not shown in the chat.
  final int hiddenChars;

  const CappedToolOutput({
    required this.toolName,
    required this.input,
    required this.text,
    required this.hiddenChars,
  });
}

/// The interactive [AgentSink]: routes agent output to the chat panel (and,
/// nominally, the spinner — which is a retired no-op today). This is the only
/// [AgentSink] implementation that imports `tina_console`; it reproduces the
/// agent's historical chat output, so the main chat is visually unchanged.
///
/// Streamed tool output (bash stdout/stderr) is printed raw up to [displayCap]
/// chars; beyond that it is buffered silently and handed to [onCapped] at
/// completion, so the full output is never lost — the `/output` viewer shows
/// it. When the tool strip lands, the host layer will swap this for a
/// composing sink that routes tool events to the strip and skips them on chat
/// while leaving text/notices on chat. The agent is oblivious to which sink it
/// has.
class ChatAgentSink implements AgentSink {
  final ScrollingTextRegion chat;
  final Spinner spinner;

  /// How much streamed tool output to print in the chat before capping.
  final int displayCap;

  /// Fired when a tool call's streamed output exceeded [displayCap], with the
  /// full text (the host keeps a ring for `/output`).
  final void Function(CappedToolOutput output)? onCapped;

  ChatAgentSink(this.chat, this.spinner,
      {this.displayCap = 600, this.onCapped});

  /// The current tool call's accumulated streamed output (from [toolStart] to
  /// [toolComplete]). Tool calls run one at a time per agent, so a single
  /// buffer is safe.
  final StringBuffer _buffer = StringBuffer();
  String _toolName = '';
  Map<String, dynamic> _toolInput = const {};
  bool _capped = false;

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
  void toolStart(ToolStartEvent e) {
    _buffer.clear();
    _toolName = e.toolName;
    _toolInput = e.input;
    _capped = false;
    chat.dim('→ ${_describe(e.toolName, e.input)}\n');
  }

  @override
  void toolOutput(ToolOutputEvent e) {
    // Always buffer the full output; print only while it fits under the cap.
    _buffer.write(e.chunk);
    if (_capped) return;
    final before = _buffer.length - e.chunk.length;
    final room = displayCap - before;
    if (room <= 0) {
      _capped = true;
      return;
    }
    final show = e.chunk.length <= room ? e.chunk : e.chunk.substring(0, room);
    e.stderr ? chat.red(show) : chat.dim(show);
    if (e.chunk.length > room) _capped = true;
  }

  @override
  void toolComplete(ToolCompleteEvent e) {
    final full = _buffer.toString();
    if (_capped) {
      chat.dim('  … (${full.length - displayCap} more chars — '
          '/output for the full output)\n');
      onCapped?.call(CappedToolOutput(
        toolName: _toolName,
        input: _toolInput,
        text: full,
        hiddenChars: full.length - displayCap,
      ));
    }
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
      case 'glob':
      case 'grep':
        // Both read-only search tools take `pattern` (required) and `path`
        // (optional); show the pattern, and the path when the caller set one.
        final pattern = input['pattern'] as String?;
        if (pattern == null) return name;
        final path = input['path'] as String?;
        return path != null ? '$name: $pattern in $path' : '$name: $pattern';
      case 'search':
        // The code-graph search tool's query lives under `symbol`.
        final symbol = input['symbol'] as String?;
        return symbol != null ? 'search: $symbol' : name;
      default:
        return _summarize(name, input);
    }
  }

  /// Compact one-line summary for tools without a dedicated case, so no tool
  /// call hides its arguments. Renders `name: k=v k=v ...` and truncates the
  /// whole summary to the same 80-char budget as the bash command, keeping it
  /// short for narrow panels.
  String _summarize(String name, Map<String, dynamic> input) {
    if (input.isEmpty) return name;
    final parts = <String>[];
    for (final entry in input.entries) {
      final value = entry.value;
      if (value == null) continue;
      final rendered = value is String ? value : value.toString();
      parts.add('${entry.key}=$rendered');
    }
    final joined = parts.join(' ');
    return joined.isEmpty ? name : '$name: ${_truncate(joined, 80)}';
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}
