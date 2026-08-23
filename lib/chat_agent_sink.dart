import 'package:tina_console/tina_console.dart';

import 'package:tina_engine/tina_engine.dart';

import 'tui/markdown_renderer.dart';

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

  /// Fired whenever the current assistant turn's raw markdown grows a closed
  /// segment (prose end), with the whole turn's raw text so far — the raw
  /// view behind the Ctrl+R viewer. The sink never styles this; it is the
  /// model's bytes, verbatim.
  final void Function(String text)? onRawText;

  ChatAgentSink(this.chat, this.spinner,
      {this.displayCap = 600, this.onCapped, this.onRawText});

  /// Drop the accumulated raw markdown for this turn (a new user message
  /// starts a new turn). Called by the host when it shows the user's line.
  /// Any splitter-held remainder from a canceled turn is abandoned with it.
  void beginAssistantTurn() {
    _raw.clear();
    _md = null;
    _wroteBlock = false;
  }

  /// The current tool call's accumulated streamed output (from [toolStart] to
  /// [toolComplete]). Tool calls run one at a time per agent, so a single
  /// buffer is safe.
  final StringBuffer _buffer = StringBuffer();
  String _toolName = '';
  Map<String, dynamic> _toolInput = const {};
  bool _capped = false;

  // --- streamed markdown state (tin-g7rk) ---

  /// The turn's raw markdown, byte-for-byte as the model sent it. Grows with
  /// every [text] delta; handed to [onRawText] as segments close; cleared by
  /// [beginAssistantTurn].
  final StringBuffer _raw = StringBuffer();

  /// Carves the stream into closed markdown blocks. Null until the first
  /// non-passthrough [text] delta (headless prose must stay verbatim, so the
  /// splitter is never even constructed there).
  MarkdownStreamSplitter? _md;

  /// Whether a rendered block has been written since the last turn boundary;
  /// drives the blank separator between consecutive blocks.
  bool _wroteBlock = false;

  /// Markdown rendering is active on color surfaces only. Passthrough
  /// (headless `--prompt`, piped output) keeps the byte-for-byte legacy path.
  bool get _markdownActive => !chat.screen.passthrough;

  @override
  void text(String s) {
    _raw.write(s);
    if (!_markdownActive) {
      // Verbatim: the policy layer only picks the style code; the surface
      // owns the passthrough/color/detached fallback (inside
      // [ScrollingTextRegion.appendStyled]).
      chat.beginStyle(chat.screen.theme.chat.agentText);
      chat.appendStyled(s); // stays open across chunks; closed by next plain write
      return;
    }
    final blocks = (_md ??= MarkdownStreamSplitter()).push(s);
    for (final block in blocks) {
      _writeMarkdownBlock(block);
    }
    if (blocks.isNotEmpty) _fireRaw(); // a segment just closed
  }

  /// Render one closed block of markdown onto the chat. One block = one
  /// [beginStyle]/[endStyle] span per line, so wraps and the bar (code) style
  /// are carried by the region, never re-flowed later.
  void _writeMarkdownBlock(String source) {
    if (_wroteBlock) chat.write('\n'); // blank line between blocks
    final style = MarkdownStyle.fromChatTheme(chat.screen.theme.chat);
    final styled = chat.screen.ansi.useColor;
    for (final line in renderMarkdown(source, style)) {
      if (line.isBlank) {
        chat.write('\n');
        continue;
      }
      final ser = serializeLine(line, style, styled: styled);
      chat.beginStyle(ser.bar ?? style.base);
      if (ser.text.isNotEmpty) chat.appendStyled(ser.text);
      chat.appendStyled('\n');
      chat.endStyle();
    }
    _wroteBlock = true;
  }

  /// Render and emit any block still held back by the splitter, then hand the
  /// turn's raw markdown to [onRawText]. Called at every prose end ([newline],
  /// [toolStart], [notice]) — never mid-paragraph.
  void _flushMarkdown() {
    final md = _md;
    if (md == null) return;
    final rest = md.flush();
    if (rest.trim().isNotEmpty) _writeMarkdownBlock(rest);
    _fireRaw();
  }

  void _fireRaw() {
    if (_raw.isNotEmpty) onRawText?.call(_raw.toString());
  }

  @override
  void newline() {
    _flushMarkdown();
    _wroteBlock = false;
    chat.newline();
  }

  @override
  void toolStart(ToolStartEvent e) {
    _flushMarkdown(); // a tool call ends prose: nothing may stay held back
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
    _flushMarkdown(); // a notice interrupts prose: flush what is held
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
