import 'package:tina_console/tina_console.dart';

import 'package:tina_engine/tina_engine.dart';

import 'chat_transcript.dart';
import 'markdown_renderer.dart';
import 'chat_renderer.dart';
import '../frontend/renderers.dart';

/// The one-line marker this sink writes for a reasoning block, until the
/// transcript renders reasoning as a block with a count.
///
/// Owned here rather than by the engine: what a reader sees is the *sink's*
/// decision, and the engine now hands over the model's reasoning text instead
/// of a pre-collapsed label (see `AgentSink.reasoning`).
const kReasoningRow = '▸ Reasoning (collapsed)';

/// Shown once per conversation, when folding first becomes possible: the block
/// cursor is the payoff of the transcript model and nothing else announces it.
const kFoldHint = '^B folds blocks · /blocks lists them';

/// How much of one tool call's output is kept behind its header. A `bash` call
/// can emit megabytes; the block is the only place this lives, so it is bounded
/// rather than trusting the command. Both ends are capped: a 50,000-line dump
/// would otherwise become 50,000 rows in the transcript's scrollback.
const int kBlockBodyLimit = 64 * 1024;
const int kBlockBodyLines = 200;

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
  final Renderers renderers;

  /// How much streamed tool output to print in the chat before capping.
  final int displayCap;

  /// Fired whenever the current assistant turn's raw markdown grows a closed
  /// segment (prose end), with the whole turn's raw text so far — the raw
  /// view behind the Ctrl+R viewer. The sink never styles this; it is the
  /// model's bytes, verbatim.
  final void Function(String text)? onRawText;

  ChatAgentSink(
    this.chat,
    this.spinner, {
    this.displayCap = 600,
    this.renderers = const Renderers(),
    this.onRawText,
    ChatSpeaker? speaker,
  }) : speaker = speaker ?? const ChatSpeaker(id: 'main', label: 'main');

  /// Who this sink's agent is. A spawned or delegated conversation's panel
  /// title names *it*; its transcript rows are anonymous like every other
  /// conversation's.
  final ChatSpeaker speaker;

  // --- the transcript -------------------------------------------------------

  /// What the chat shows, in order. This is the source of truth: a tool call's
  /// status lands here when the call finishes, a resize re-renders from here,
  /// and folding will rewrite from here. Rows are derived, never edited.
  final List<ChatBlock> _blocks = [];

  /// Region content row where each block starts, and how many rows it took —
  /// parallel to [_blocks], so a block can be repainted in place.
  final List<int> _blockRow = [];
  final List<int> _blockRows = [];

  /// Content rows this sink has painted (blocks plus their blank separators).
  int _rows = 0;

  /// Whether the fold hint has been shown. Once per conversation: a hint is
  /// only useful the first time there is something to fold.
  bool _hintedFolding = false;

  /// Index of the block the transcript cursor is on, if it is open.
  int? _highlighted;

  /// Index of the tool call currently in flight, so its header can be repainted
  /// with the outcome when it completes. A call runs one at a time per agent.
  int? _toolBlock;

  /// Blocks are painted on a colour surface. Passthrough (piped output,
  /// `--backend`-less runs) keeps the legacy byte-for-byte rendering: it is not
  /// a layout we own, and its consumers parse it.
  bool get _blocksActive => !chat.screen.passthrough;

  int get _width => chat.bounds.width;

  MarkdownStyle get _style =>
      MarkdownStyle.fromChatTheme(chat.screen.theme.chat);

  /// Drop the accumulated raw markdown for this turn (a new user message
  /// starts a new turn). Called by the host when it shows the user's line.
  /// Any splitter-held remainder from a canceled turn is abandoned with it.
  void beginAssistantTurn() {
    _raw.clear();
    _md = null;
  }

  // --- settled approvals ----------------------------------------------------

  /// One settled approval record, queued by the permission modal.
  ///
  /// The modal answers *before* the engine starts the tool, so it cannot write
  /// into the transcript at that moment: the tool row would come after it and
  /// the call would be printed twice (once as the card's preview, once as the
  /// row). Instead the record is queued here and printed by the sink, once,
  /// *after* the row it belongs to.
  String? _pendingApproval;

  /// Queue the settled approval record ([record] carries its own trailing
  /// newline). It prints at the next tool row, notice or prose boundary —
  /// see [flushApproval].
  void queueApproval(String record) {
    // A record still waiting when the next approval settles (a cancelled call,
    // whose tool never started) prints now rather than being dropped.
    flushApproval();
    _pendingApproval = record;
  }

  /// Print the queued approval record, if any.
  ///
  /// It lands as its own notice block so a later repaint keeps it — a raw
  /// write between blocks is not part of the transcript the sink rebuilds
  /// from.
  void flushApproval() {
    final record = _pendingApproval;
    if (record == null) return;
    _pendingApproval = null;
    if (_blocksActive) {
      _flushMarkdown(); // prose must not be held across the record's block
      _add(ChatBlock.notice(speaker, record.trim()));
      return;
    }
    chat.ensureNewline();
    chat.dim(record.endsWith('\n') ? record : '$record\n');
  }

  /// The current tool call's accumulated streamed output (from [toolStart] to
  /// [toolComplete]). Tool calls run one at a time per agent, so a single
  /// buffer is safe.
  final StringBuffer _buffer = StringBuffer();
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

  /// Markdown rendering is active on color surfaces only. Passthrough
  /// (headless `--prompt`, piped output) keeps the byte-for-byte legacy path.
  bool get _markdownActive => !chat.screen.passthrough;

  // --- painting -------------------------------------------------------------

  /// Append [block] to the transcript and paint it. Blocks are append-only:
  /// only a tool call's own header is ever repainted (it gains its outcome),
  /// and that is the last block on screen.
  void _add(ChatBlock block) {
    if (_blocks.isNotEmpty) {
      chat.write('\n'); // blank line between blocks
      _rows++;
    }
    _blocks.add(block);
    _blockRow.add(_rows);
    final lines = _render(block);
    _blockRows.add(lines.length);
    _writeLines(lines);
    _rows += lines.length;
    _maybeHintFolding();
  }

  /// Mention the fold cursor once per conversation, the first time a block
  /// becomes foldable. A tool call is added as a header and only gains its body
  /// when it completes, so this is checked both when a block is painted and
  /// when one is repainted with its output.
  void _maybeHintFolding() {
    if (_hintedFolding) return;
    if (!_blocks.any((block) => block.canFold)) return;
    _hintedFolding = true;
    _add(ChatBlock.notice(speaker, kFoldHint));
  }

  /// Repaint the block at [index], whose rows are the tail of the transcript.
  void _repaintBlock(int index) {
    if (index != _blocks.length - 1) {
      rerender();
      _maybeHintFolding();
      return;
    }
    final block = _blocks[index];
    final lines = _render(block);
    chat.rewriteFrom(_blockRow[index], _regionLines(lines, index));
    _rows += lines.length - _blockRows[index];
    _blockRows[index] = lines.length;
    _maybeHintFolding();
  }

  /// Paint every block again from scratch, rebuilding the row index. The
  /// region re-flows its own rows on a resize, so the host calls this after
  /// one.
  void rerender() {
    if (!_blocksActive || _blocks.isEmpty) return;
    final out = <RegionLine>[];
    _blockRow.clear();
    _blockRows.clear();
    _rows = 0;
    for (var i = 0; i < _blocks.length; i++) {
      if (i > 0) {
        out.add(const RegionLine(''));
        _rows++;
      }
      final lines = _render(_blocks[i]);
      _blockRow.add(_rows);
      _blockRows.add(lines.length);
      out.addAll(_regionLines(lines, i));
      _rows += lines.length;
    }
    chat.rewriteFrom(0, out);
  }

  /// Forget the transcript, so the next block starts at the top of a cleared
  /// region. The host calls this alongside the region's own clear.
  void clearTranscript() {
    _blocks.clear();
    _blockRow.clear();
    _blockRows.clear();
    _rows = 0;
    _toolBlock = null;
    _highlighted = null;
    _hintedFolding = false; // a cleared transcript can hint again
  }

  void _writeLines(List<RenderLine> lines) {
    final style = _style;
    final styled = chat.screen.ansi.useColor;
    for (final line in lines) {
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
  }

  RegionLine _regionLine(RenderLine line, [String? rowStyle]) {
    if (line.isBlank) return const RegionLine('');
    if (rowStyle != null) line = RenderLine(bar: rowStyle, runs: line.runs);
    final ser = serializeLine(line, _style, styled: chat.screen.ansi.useColor);
    return RegionLine(ser.text, bar: ser.bar);
  }

  List<RenderLine> _render(ChatBlock block) => renderers.render(
    block,
    RenderContext(width: _width, theme: chat.screen.theme),
    fallback: const ChatRenderer(),
  );

  /// The user's own message: its own block, under the `you` speaker.
  void userMessage(String text) {
    flushApproval(); // a record left from the previous turn prints before it
    final body = text.endsWith('\n')
        ? text.substring(0, text.length - 1)
        : text;
    if (!_blocksActive) {
      chat.writeStyledLine('• $body', chat.screen.theme.chat.userText);
      return;
    }
    _flushMarkdown();
    _add(ChatBlock.user(body));
  }

  // --- folding --------------------------------------------------------------

  /// The transcript, in order, for the host to fold and list.
  List<ChatBlock> get blocks => List.unmodifiable(_blocks);

  /// Flip the block at [index] between its one-line form and its body. Returns
  /// false when the block cannot fold — prose and the user's own words are
  /// never collapsed, and a tool call whose output was not retained has nothing
  /// behind its header.
  bool toggleFold(int index) {
    if (index < 0 || index >= _blocks.length) return false;
    final block = _blocks[index];
    if (!block.canFold) return false;
    block.folded = !block.folded;
    _relayout();
    return true;
  }

  /// Fold or unfold every block that can fold. Returns how many changed.
  int setAllFolds({required bool folded}) {
    var changed = 0;
    for (final block in _blocks) {
      if (!block.canFold || block.folded == folded) continue;
      block.folded = folded;
      changed++;
    }
    if (changed > 0) _relayout();
    return changed;
  }

  /// The indexes of the blocks that can fold, in order — what `/blocks` lists
  /// and what the transcript cursor steps through.
  List<int> get foldableIndexes => [
    for (var i = 0; i < _blocks.length; i++)
      if (_blocks[i].canFold) i,
  ];

  /// The region row a block starts at, so a caller can bring it into view.
  int? rowOfBlock(int index) =>
      index >= 0 && index < _blockRow.length ? _blockRow[index] : null;

  /// The region row a block *ends* at — its last painted row. Revealing a block
  /// should show its contents, so a cursor scrolls to this rather than to the
  /// header it just expanded.
  int? endRowOfBlock(int index) => index >= 0 && index < _blockRows.length
      ? _blockRow[index] + _blockRows[index] - 1
      : null;

  /// Mark the selected header. Rebuild rows so renderer height changes and
  /// selection in the middle of the transcript cannot discard later blocks.
  void highlightBlock(int? index) {
    if (!_blocksActive || _highlighted == index) return;
    _highlighted = index;
    rerender();
  }

  List<RegionLine> _regionLines(List<RenderLine> lines, int index) {
    final header = lines.indexWhere((line) => !line.isBlank);
    return [
      for (var i = 0; i < lines.length; i++)
        _regionLine(
          lines[i],
          _highlighted == index && i == header
              ? chat.screen.theme.border.selection
              : null,
        ),
    ];
  }

  /// Repaint after a fold. Folding a block anywhere but the end changes how
  /// many rows every block after it occupies, so the row index is rebuilt and
  /// the transcript repainted from the top — a user action, not a delta.
  void _relayout() => rerender();

  /// One-line description of a tool call for its header. Not truncated here:
  /// the renderer keeps the head *and* tail of whatever does not fit, and it is
  /// the one that knows the width.
  String _subject(String name, Map<String, dynamic> input) {
    switch (name) {
      case 'exec':
        return '$name · ${input['executable']} ${input['args'] ?? []}';
      case 'bash':
        final cmd = input['command'] as String?;
        return cmd != null ? '$name · $cmd' : name;
      case 'read':
      case 'write':
      case 'edit':
        final path = input['filePath'] as String?;
        return path != null ? '$name · $path' : name;
      case 'glob':
      case 'grep':
        final pattern = input['pattern'] as String?;
        if (pattern == null) return name;
        final path = input['path'] as String?;
        return path != null ? '$name · $pattern in $path' : '$name · $pattern';
      case 'search':
        final symbol = input['symbol'] as String?;
        return symbol != null ? '$name · $symbol' : name;
      default:
        if (input.isEmpty) return name;
        final parts = <String>[];
        for (final entry in input.entries) {
          final value = entry.value;
          if (value == null) continue;
          parts.add('${entry.key}=$value');
        }
        return parts.isEmpty ? name : '$name · ${parts.join(' ')}';
    }
  }

  /// The header's trailing detail: the outcome, how long it took, and — for a
  /// failure — the first line of what went wrong. Header-only rendering hides
  /// the body, and a failure a reader cannot see is worse than a long row.
  String _outcome(ToolCompleteEvent e, String produced) {
    final timing = _timing(e.elapsed);
    if (!e.isError) return timing.isEmpty ? 'ok' : 'ok · $timing';
    final why = produced
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    final head = why.length > 60 ? '${why.substring(0, 59)}…' : why;
    return [
      'failed',
      if (timing.isNotEmpty) timing,
      if (head.isNotEmpty) head,
    ].join(' · ');
  }

  /// The body a fold will reveal: the head of the output, capped by lines and
  /// by bytes so a runaway dump cannot become the transcript.
  String _bodyOf(String produced) {
    var text = produced;
    if (text.length > kBlockBodyLimit) {
      text =
          '${text.substring(0, kBlockBodyLimit)}\n'
          '… (truncated at $kBlockBodyLimit chars)';
    }
    final lines = text.split('\n');
    if (lines.length <= kBlockBodyLines) return text;
    return '${lines.take(kBlockBodyLines).join('\n')}\n'
        '… (${lines.length - kBlockBodyLines} more lines)';
  }

  @override
  void text(String s) {
    flushApproval(); // prose starts with nothing waiting behind it
    _raw.write(s);
    if (!_markdownActive) {
      // Verbatim: the policy layer only picks the style code; the surface
      // owns the passthrough/color/detached fallback (inside
      // [ScrollingTextRegion.appendStyled]).
      chat.beginStyle(chat.screen.theme.chat.agentText);
      chat.appendStyled(
        s,
      ); // stays open across chunks; closed by next plain write
      return;
    }
    final blocks = (_md ??= MarkdownStreamSplitter()).push(s);
    for (final block in blocks) {
      _addProse(block);
    }
    if (blocks.isNotEmpty) _fireRaw(); // a segment just closed
  }

  /// Render one closed block of markdown as a transcript block. Markdown is
  /// parsed once, here: what the block holds are finished lines, so re-rendering
  /// it later (a resize, a fold) is layout only.
  void _addProse(String source) {
    _add(ChatBlock.prose(speaker, renderMarkdown(source, _style)));
  }

  /// Render and emit any block still held back by the splitter, then hand the
  /// turn's raw markdown to [onRawText]. Called at every prose end ([newline],
  /// [toolStart], [notice]) — never mid-paragraph.
  void _flushMarkdown() {
    final md = _md;
    if (md == null) return;
    final rest = md.flush();
    if (rest.trim().isNotEmpty) _addProse(rest);
    _fireRaw();
  }

  void _fireRaw() {
    if (_raw.isNotEmpty) onRawText?.call(_raw.toString());
  }

  @override
  void newline() {
    _flushMarkdown();
    if (!_blocksActive) chat.newline(); // blocks separate themselves
  }

  /// The current reasoning block's text, accumulated from [reasoning] so a
  /// later transcript layer can show it (and expand it) rather than only
  /// counting it. Cleared at every block boundary.
  final StringBuffer _reasoning = StringBuffer();

  /// Reasoning accumulates and lands as one block when the thought ends: the
  /// header carries the count, so a reasoning-heavy model costs one row.
  @override
  void reasoning(String text, {bool startsBlock = false}) {
    if (startsBlock) {
      _reasoning.clear();
      _flushMarkdown(); // reasoning interrupts prose
      if (!_blocksActive) {
        chat.ensureNewline();
        chat.dim('\n$kReasoningRow\n');
      }
    }
    _reasoning.write(text);
  }

  /// The block ended: paint it. A partial block says so in its header, because
  /// the provider cut the thought off.
  @override
  void reasoningEnd({required bool complete}) {
    final text = _reasoning.toString();
    _reasoning.clear();
    if (_blocksActive) {
      if (text.isNotEmpty) {
        _add(ChatBlock.reasoning(speaker, text, complete: complete));
      }
      return;
    }
    if (!complete) {
      chat.ensureNewline();
      chat.dim('$kReasoningRow — partial\n');
    }
  }

  @override
  void toolStart(ToolStartEvent e) {
    _flushMarkdown(); // a tool call ends prose: nothing may stay held back
    _buffer.clear();
    _capped = false;
    if (!_blocksActive) {
      chat.dim('→ ${describeToolCall(e.toolName, e.input)}\n');
      _toolBlock = null;
      flushApproval(); // after the row: an approval never precedes its call
      return;
    }
    // Header only: what the call produces is retained (see [toolComplete]) and
    // belongs behind the header, not printed under it.
    _add(ChatBlock.toolCall(speaker, subject: _subject(e.toolName, e.input)));
    _toolBlock = _blocks.length - 1;
    flushApproval(); // after the row: an approval never precedes its call
  }

  @override
  void toolOutput(ToolOutputEvent e) {
    _buffer.write(e.chunk);
    if (_blocksActive) return; // the block holds it; nothing is printed
    // Passthrough keeps the legacy stream: print while it fits under the cap.
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
    flushApproval(); // a call that never started (cancel) still gets its record
    final streamed = _buffer.toString();
    // Whichever the tool produced more of: a failure's `result` carries the
    // message, a success's streamed output carries the work. Taking the longer
    // keeps what the two previous code paths each retained.
    final produced = e.result.length > streamed.length ? e.result : streamed;

    if (_blocksActive) {
      final index = _toolBlock;
      _toolBlock = null;
      if (index != null && index < _blocks.length) {
        final block = _blocks[index];
        block.status = _outcome(e, produced);
        // An empty result is no body at all: `plainLines('')` would be one
        // blank row, which would make the call look foldable and expand to
        // nothing.
        block.body = produced.trim().isEmpty
            ? const []
            : plainLines(_bodyOf(produced));
        _repaintBlock(index);
      }
      return;
    }

    if (_capped) {
      chat.dim(
        '  … (${streamed.length - displayCap} more chars — '
        '/output for the full output)\n',
      );
    }
    final timing = _timing(e.elapsed);
    if (e.isError) {
      const cap = 200;
      // The duration goes in parentheses here: `failed · 1.4s: boom` reads as
      // if the timing were part of the message.
      chat.red(
        '  failed${timing.isEmpty ? '' : ' ($timing)'}: '
        '${_truncate(e.result, cap)}\n',
      );
      if (e.result.length > cap) {
        // The printed render cut the error off; point at the retained copy.
        chat.dim('  … (/output for the full error)\n');
      }
    } else {
      chat.dim('  ok${timing.isEmpty ? '' : ' · $timing'}\n');
    }
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
    flushApproval(); // a denied call's record comes before the denial itself
    _flushMarkdown(); // a notice interrupts prose: flush what is held
    if (_blocksActive) {
      // Severity is a *word* here, not a glyph: the markers worth having
      // (U+26A0 and friends) are East Asian Ambiguous, which tina's width
      // table counts as one cell while some terminals lay out as two.
      _add(
        ChatBlock.notice(
          speaker,
          message.trim(),
          notice: switch (kind) {
            NoticeKind.info => null,
            NoticeKind.warning => 'warn',
            NoticeKind.error => 'error',
          },
        ),
      );
    } else {
      // Terminate any open row first: a notice drawn over unterminated streamed
      // output glues onto its tail, like the #30 prompts did (#31).
      chat.ensureNewline();
      switch (kind) {
        case NoticeKind.info:
          chat.dim(message);
        case NoticeKind.warning:
          chat.yellow(message);
        case NoticeKind.error:
          chat.red(message);
      }
    }
  }

  @override
  void activityStart() => spinner.start();

  @override
  void activityStop() => spinner.stop();
}

// --- description / truncation helpers (moved from agent.dart) ---

/// One-line description of a tool call: `bash: git status`, `edit: path`.
///
/// This is the form the passthrough tool row and the settled approval record
/// print (the block header has its own, [ChatAgentSink]-side subject). It is
/// shared with the approval so a call that gets *no* row of its own — denied
/// or cancelled — still names itself exactly once in the transcript.
///
/// Not truncated here: the renderer keeps the head *and* tail of whatever does
/// not fit, and it is the one that knows the width.
String describeToolCall(String name, Map<String, dynamic> input) {
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
