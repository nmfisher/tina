import 'package:tina_console/tina_console.dart';

import 'package:tina_engine/tina_engine.dart';

import 'markdown_renderer.dart';

/// The one-line marker this sink writes for a reasoning block, until the
/// transcript renders reasoning as a block with a count.
///
/// Owned here rather than by the engine: what a reader sees is the *sink's*
/// decision, and the engine now hands over the model's reasoning text instead
/// of a pre-collapsed label (see `AgentSink.reasoning`).
const kReasoningRow = '▸ Reasoning (collapsed)';

/// One tool call's output, kept so it can be read on demand.
///
/// Recorded for **every** completed call, not only ones whose chat render was
/// capped: the transcript shows a tool call as a single header row, so the
/// output behind it has to live somewhere or there would be nothing to reveal.
/// The host keeps the most recent few for `/output`.
class ToolCallOutput {
  final String toolName;
  final Map<String, dynamic> input;

  /// The call's output, truncated to [kRetainedOutputLimit] characters; the
  /// tail of a pathological dump is dropped rather than held in memory.
  final String text;

  const ToolCallOutput({
    required this.toolName,
    required this.input,
    required this.text,
  });
}

/// How much of one tool call's output is retained for on-demand reading. A
/// `bash` call can emit megabytes; the transcript only ever shows a header, so
/// this bounds what a long session holds in memory. The `/output` viewer says
/// when it is showing a truncated dump.
const int kRetainedOutputLimit = 64 * 1024;

/// The interactive [AgentSink]: routes agent output to the chat panel (and,
/// nominally, the spinner — which is a retired no-op today). This is the only
/// [AgentSink] implementation that imports `tina_console`.
///
/// Streamed tool output (bash stdout/stderr) is printed raw up to [displayCap]
/// chars, and every call's output is handed to [onToolOutput] at completion so
/// it can be read afterwards — the `/output` viewer shows it, and the
/// transcript's tool rows will reveal it in place.
class ChatAgentSink implements AgentSink {
  final ScrollingTextRegion chat;
  final Spinner spinner;

  /// How much streamed tool output to print in the chat before capping.
  final int displayCap;

  /// Fired once per completed tool call with what it produced (truncated to
  /// [kRetainedOutputLimit]) — the host keeps a ring for `/output`. Fired
  /// whether or not the chat render was capped, because the transcript shows a
  /// call as a header and the output has to be available behind it.
  final void Function(ToolCallOutput output)? onToolOutput;

  /// Fired whenever the current assistant turn's raw markdown grows a closed
  /// segment (prose end), with the whole turn's raw text so far — the raw
  /// view behind the Ctrl+R viewer. The sink never styles this; it is the
  /// model's bytes, verbatim.
  final void Function(String text)? onRawText;

  /// Mirrors warning/error notices to the dedicated error strip beneath the
  /// input box (bottom border row). Null = chat scrollback only. Info
  /// notices never reach the strip.
  final void Function(String text, {required bool error})? onStrip;

  ChatAgentSink(this.chat, this.spinner,
      {this.displayCap = 600, this.onToolOutput, this.onRawText, this.onStrip});

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

  /// The current reasoning block's text, accumulated from [reasoning] so a
  /// later transcript layer can show it (and expand it) rather than only
  /// counting it. Cleared at every block boundary.
  final StringBuffer _reasoning = StringBuffer();

  /// A reasoning block opens on its first chunk. The marker goes out then, not
  /// at the end: a long thinking phase should show that it is thinking, which
  /// is what the engine's old notice did too.
  @override
  void reasoning(String text, {bool startsBlock = false}) {
    if (startsBlock) {
      _reasoning.clear();
      _flushMarkdown(); // reasoning interrupts prose
      chat.ensureNewline();
      chat.dim('\n$kReasoningRow\n');
    }
    _reasoning.write(text);
  }

  /// The block ended. A partial block says so on its own line — the provider cut
  /// the thought off, so the marker above would otherwise imply a complete one.
  @override
  void reasoningEnd({required bool complete}) {
    if (!complete) {
      chat.ensureNewline();
      chat.dim('$kReasoningRow — partial\n');
    }
    _reasoning.clear();
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
    final streamed = _buffer.toString();
    // Whichever the tool produced more of: a failure's `result` carries the
    // message, a success's streamed output carries the work. Taking the longer
    // keeps what the two previous code paths each retained.
    final produced =
        e.result.length > streamed.length ? e.result : streamed;

    if (_capped) {
      chat.dim('  … (${streamed.length - displayCap} more chars — '
          '/output for the full output)\n');
    }
    final timing = _timing(e.elapsed);
    if (e.isError) {
      const cap = 200;
      // The duration goes in parentheses here: `failed · 1.4s: boom` reads as
      // if the timing were part of the message.
      chat.red('  failed${timing.isEmpty ? '' : ' ($timing)'}: '
          '${_truncate(e.result, cap)}\n');
      if (e.result.length > cap) {
        // The printed render cut the error off; point at the retained copy.
        chat.dim('  … (/output for the full error)\n');
      }
    } else {
      chat.dim('  ok${timing.isEmpty ? '' : ' · $timing'}\n');
    }

    // One record per call, whatever happened, so the output is readable after
    // the fact — whether or not the chat render was capped.
    onToolOutput?.call(ToolCallOutput(
      toolName: _toolName,
      input: _toolInput,
      text: produced.length > kRetainedOutputLimit
          ? '${produced.substring(0, kRetainedOutputLimit)}\n'
              '… (truncated at $kRetainedOutputLimit chars)'
          : produced,
    ));
  }

  /// A measured duration as `41ms` / `1.4s` / `2m 3s`, or empty when the tool
  /// did not time itself. Each call site adds its own punctuation.
  String _timing(Duration? elapsed) {
    if (elapsed == null || elapsed <= Duration.zero) return '';
    final ms = elapsed.inMilliseconds;
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s';
  }

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {
    _flushMarkdown(); // a notice interrupts prose: flush what is held
    // Terminate any open row first: a notice drawn over unterminated
    // streamed output glues onto its tail, like the #30 prompts did (#31).
    chat.ensureNewline();
    switch (kind) {
      case NoticeKind.info:
        chat.dim(message);
      case NoticeKind.warning:
        chat.yellow(message);
      case NoticeKind.error:
        chat.red(message);
    }
    if (kind != NoticeKind.info) {
      onStrip?.call(message.trim(), error: kind == NoticeKind.error);
    }
  }

  @override
  void activityStart() => spinner.start();

  @override
  void activityStop() => spinner.stop();

  // --- description / truncation helpers (moved from agent.dart) ---

  String _describe(String name, Map<String, dynamic> input) {
    switch (name) {
      case 'exec':
        return 'exec: ${input['executable']} ${input['args'] ?? []}';
      case 'bash':
        final cmd = input['command'] as String?;
        // Head+tail: the tail of a long command is where the risk lives (a
        // `| sh`, a trailing `; rm`, the redirect target) and the approval
        // prompt it came from has long since scrolled away.
        return cmd != null ? 'bash: ${_truncateHeadTail(cmd)}' : name;
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
    // Same head+tail treatment as the bash row: a long `k=v` summary keeps
    // both ends so the value's tail is still visible in the tool row.
    return joined.isEmpty ? name : '$name: ${_truncateHeadTail(joined)}';
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  /// [s] shortened to roughly [max] chars, keeping its head AND its tail —
  /// for tool-row subjects whose tail carries meaning even though the head is
  /// the familiar part. Up to [max] chars renders verbatim; longer input
  /// renders as `<first [head] chars>…<last chars>` (total stays within
  /// [max]).
  String _truncateHeadTail(String s, {int max = 80, int head = 52}) {
    final tail = max - head - 1;
    return s.length <= max
        ? s
        : '${s.substring(0, head)}…${s.substring(s.length - tail)}';
  }
}
