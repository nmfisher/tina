/// The transcript layer: what the chat is made of, and how it is laid out.
///
/// Today the chat is an append-only stream of styled rows — a tool call, its
/// output, an error and a notice are all just text at column 0, told apart by
/// colour alone. This layer gives those rows a *structure*: an ordered list of
/// [ChatBlock]s, each belonging to a [ChatSpeaker], each either folded (one
/// line) or expanded. [renderTranscript] turns that list into wrapped,
/// gutter-prefixed [MarkdownLine]s.
///
/// Two rules the types are built around:
///
///  * **The gutter names the speaker, the glyph names the kind.** A delegated
///    agent's tool call reads `scout │ → bash · …` with no extra concepts, so
///    the layout scales to many agents without a per-kind label vocabulary.
///    [ChatSpeaker.label] is the same role string the panel title uses, so the
///    gutter and the border cannot disagree.
///  * **Nothing here touches a Screen.** Every styling decision resolves
///    through the caller's runs and theme; the renderer is a pure function from
///    blocks + width to lines, so it can be golden-tested without a terminal.
///
/// Wrapping lives here rather than in the region because a wrapped line's
/// continuation must carry the same blank gutter as its first line. The region
/// wraps at its own width and knows nothing about gutters, so a line handed to
/// it already fits and its own wrap becomes a no-op.
library;

import 'package:tina_console/tina_console.dart';

import 'markdown_renderer.dart';

/// What a block is. Decides its glyph and whether it starts folded.
///
/// [user] and [prose] are the conversation itself and never fold. [reasoning]
/// and [toolCall] are the agent's working-out: they fold by default, so a
/// twenty-call turn stays scannable, and expand in place when asked.
enum ChatBlockKind {
  user,
  prose,
  reasoning,
  toolCall,
  notice;

  /// Whether this kind starts folded. Reasoning is hidden with a count and a
  /// tool call shows its header only; prose and the user's own words are
  /// always fully visible.
  bool get startsFolded =>
      this == ChatBlockKind.reasoning || this == ChatBlockKind.toolCall;

  /// Whether the user may fold this kind at all.
  bool get canFold => startsFolded;
}

/// Who a block belongs to.
///
/// [label] is the role the conversation runs as — `you`, `main`, `scout` — and
/// is deliberately the same string the panel title is built from, so the two
/// surfaces name an agent identically. [id] identifies the conversation/agent,
/// which is what a future multi-agent view needs to route one agent's blocks
/// into its own panel.
class ChatSpeaker {
  const ChatSpeaker({required this.id, required this.label});

  /// The conversation or agent this speaker is.
  final String id;

  /// The role shown in the gutter.
  final String label;

  /// The user's own messages. Their "role" is a view of the conversation, not
  /// a configured agent, so the label is fixed rather than resolved.
  static const you = ChatSpeaker(id: 'user', label: 'you');

  @override
  bool operator ==(Object other) =>
      other is ChatSpeaker && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'ChatSpeaker($label)';
}

/// One block of the transcript.
///
/// The caller renders content into [body] (markdown runs for prose, plain runs
/// for everything else) and supplies [subject]/[status] for the one-line form
/// of a foldable block. The transcript owns [folded]; nothing else mutates it.
class ChatBlock {
  ChatBlock({
    required this.speaker,
    required this.kind,
    this.body = const [],
    this.subject = '',
    this.status,
    this.notice,
    bool? folded,
  }) : folded = folded ?? kind.startsFolded;

  /// A message from the user.
  factory ChatBlock.user(String text,
          {ChatSpeaker speaker = ChatSpeaker.you}) =>
      ChatBlock(speaker: speaker, kind: ChatBlockKind.user, subject: text);

  /// A paragraph of the agent's answer, already rendered from markdown.
  factory ChatBlock.prose(ChatSpeaker speaker, List<MarkdownLine> lines) =>
      ChatBlock(speaker: speaker, kind: ChatBlockKind.prose, body: lines);

  /// A reasoning block. Collapsed to a count by default: the text is kept so
  /// it can be expanded in place, but a reasoning-heavy model does not get to
  /// fill the transcript with it.
  factory ChatBlock.reasoning(
    ChatSpeaker speaker,
    String text, {
    bool complete = true,
  }) =>
      ChatBlock(
        speaker: speaker,
        kind: ChatBlockKind.reasoning,
        body: plainLines(text),
        subject: complete ? 'reasoning' : 'reasoning (partial)',
        status: '${text.length} chars',
      );

  /// A tool call. [subject] is the one-line description (`bash · grep -rn …`),
  /// [status] its outcome (`ok · 41ms`, `failed · 1.4s`); [body] is the output,
  /// shown only when expanded.
  factory ChatBlock.toolCall(
    ChatSpeaker speaker, {
    required String subject,
    String? status,
    List<MarkdownLine> body = const [],
  }) =>
      ChatBlock(
        speaker: speaker,
        kind: ChatBlockKind.toolCall,
        subject: subject,
        status: status,
        body: body,
      );

  /// A notice — a status line rather than conversation. Never folds.
  ///
  /// [notice] carries the severity as a *word* (`warn`, `error`) instead of a
  /// glyph: the severity glyphs worth having (⚠ ✓ ✗) are East Asian Ambiguous,
  /// which tina's width table counts as one cell while some terminals lay them
  /// out as two — the drift behind tin-q4vz. A word is unambiguous everywhere.
  factory ChatBlock.notice(ChatSpeaker speaker, String text, {String? notice}) =>
      ChatBlock(
        speaker: speaker,
        kind: ChatBlockKind.notice,
        subject: text,
        notice: notice,
      );

  final ChatSpeaker speaker;
  final ChatBlockKind kind;

  /// Expanded content, already styled. Empty for a block whose whole value is
  /// its one-line form.
  final List<MarkdownLine> body;

  /// The one-line form's text: the user's message, a tool call's description,
  /// or a notice's text. Prose carries its content in [body] instead.
  final String subject;

  /// Optional trailing detail for the one-line form (`ok · 41ms`).
  final String? status;

  /// Optional severity word for a notice (`warn`, `error`).
  final String? notice;

  /// Whether the block is collapsed to its one-line form.
  bool folded;

  /// Whether this block has more to show than its one-line form.
  bool get hasBody => body.isNotEmpty;

  /// Whether the block can be folded at all — a block with nothing behind it
  /// (a tool call whose output was never retained) has nothing to expand.
  bool get canFold => kind.canFold && hasBody;
}

/// The shared left gutter: a right-aligned label column, a rule, and content.
///
/// ```text
///  main │ The failure is a flake in `ParserTest.rejectsBareColon`.
///       │ Two things point that way:
/// ```
///
/// The width is computed once per transcript from the speakers it contains, so
/// a two-agent conversation does not pay for a seven-letter role it never uses.
/// Continuation lines carry a blank label column, which is what makes a wrapped
/// paragraph read as one block instead of several.
class ChatGutter {
  const ChatGutter(this.labelWidth);

  /// Columns reserved for the label. 4 fits `you`/`main`; longer roles widen
  /// the gutter, bounded so a pathological role name cannot eat the transcript.
  final int labelWidth;

  static const int minLabelWidth = 4;
  static const int maxLabelWidth = 10;

  /// One leading space, the label right-aligned in its column, and ` │ `.
  int get width => labelWidth + 4;

  /// The widest label among [speakers], clamped to the allowed range. Prose
  /// inherits this too, so every line in a transcript shares one gutter.
  factory ChatGutter.forSpeakers(Iterable<ChatSpeaker> speakers) {
    var widest = minLabelWidth;
    for (final speaker in speakers) {
      final w = plainWidth(speaker.label);
      if (w > widest) widest = w;
    }
    return ChatGutter(widest > maxLabelWidth ? maxLabelWidth : widest);
  }

  /// The gutter a transcript of [blocks] needs.
  factory ChatGutter.forBlocks(Iterable<ChatBlock> blocks) =>
      ChatGutter.forSpeakers(blocks.map((b) => b.speaker));

  /// The prefix opening a block: ` main │ `. A label longer than the column is
  /// truncated rather than allowed to push the content column out.
  ///
  /// The leading space is the transcript's margin from the panel border — it is
  /// part of [width], and [continuing] carries it too, so the `│` rule is a
  /// straight line down every row.
  String opening(ChatSpeaker speaker) => ' ${_label(speaker.label)} │ ';

  /// The prefix continuing a block: `      │ `.
  String get continuing => '${' ' * (labelWidth + 1)} │ ';

  /// A nested prefix for expanded content inside a block, so a tool's output
  /// reads as belonging to the call above it. Two columns deeper than
  /// [continuing].
  String get nested => '$continuing  ';

  String _label(String label) {
    if (plainWidth(label) > labelWidth) {
      return _truncateToWidth(label, labelWidth);
    }
    return label.padLeft(labelWidth);
  }
}

/// Render [blocks] for a transcript [width] columns wide, gutter included.
///
/// Each returned line already fits [width], so the region it is written to
/// wraps nothing. Blocks are separated by a blank line; a blank line carries no
/// gutter, so the separation reads as a gap rather than an empty row.
List<MarkdownLine> renderTranscript(
  List<ChatBlock> blocks, {
  required int width,
  ChatGutter? gutter,
}) {
  final g = gutter ?? ChatGutter.forBlocks(blocks);
  final contentWidth = width - g.width;
  if (contentWidth <= 0) {
    // Too narrow for a gutter: degrade to plain content rather than emit lines
    // the region would wrap into misaligned soup.
    return [
      for (final block in blocks) ..._bodyLines(block),
    ];
  }

  final out = <MarkdownLine>[];
  for (final block in blocks) {
    if (out.isNotEmpty) out.add(const MarkdownLine.blank());
    out.addAll(_renderBlock(block, g, contentWidth));
  }
  while (out.isNotEmpty && out.last.isBlank) {
    out.removeLast();
  }
  return out;
}

List<MarkdownLine> _renderBlock(ChatBlock block, ChatGutter g, int width) {
  final opening = g.opening(block.speaker);

  if (block.kind == ChatBlockKind.prose) {
    return _prefixAll(_wrap(block.body, width), opening, g.continuing);
  }

  // The header is the same row folded or expanded — expanding reveals the body
  // underneath, it does not restyle the line above it. A notice/tool row is a
  // signpost, so it is truncated to fit rather than wrapped (wrapping splits
  // the subject from its status and breaks a long path mid-token); only a
  // not-quite-fitting block falls back to wrapping.
  final oneLine = _oneLine(block, width);
  List<MarkdownLine> header() => oneLine != null
      ? [oneLine]
      : _wrap([MarkdownLine(runs: _headerRuns(block))], width);

  final collapsed = block.folded || !block.hasBody;
  if (collapsed) {
    return _prefixAll(header(), opening, g.continuing);
  }

  // Expanded: the header, then the body nested one level in (and the body
  // wrapped one level narrower, so a nested line and a header line end in the
  // same column).
  final nestedWidth = width - (g.nested.length - g.width);
  return [
    ..._prefixAll(header(), opening, g.continuing),
    ..._prefixAll(
      _wrap(block.body, nestedWidth),
      g.nested,
      g.nested,
    ),
  ];
}

/// The one-line form as a single row that fits [width], or null when even a
/// truncated subject cannot (the caller then wraps).
///
/// The subject gives up columns first — with its head *and* tail kept, because
/// a tool row's meaning often sits at the end (a redirect target, a `| sh`) —
/// so [ChatBlock.status] always stays attached to the row it describes.
MarkdownLine? _oneLine(ChatBlock block, int width) {
  // A user message is prose, not a signpost: it wraps so no part of what the
  // user typed is replaced by an ellipsis.
  if (block.kind == ChatBlockKind.user) return null;
  final glyph = _glyph(block);
  final status = (block.status == null || block.status!.isEmpty)
      ? ''
      : '  ${block.status}';
  final room = width - plainWidth(glyph) - plainWidth(status);
  if (room <= 0) return null;
  final subject = _truncateHeadTail(block.subject, room);
  return MarkdownLine(runs: [MarkdownRun('$glyph$subject$status', null)]);
}

/// The kind's leading marker. Reasoning's triangle also reports its fold
/// state, so the state is legible without colour.
String _glyph(ChatBlock block) => switch (block.kind) {
      ChatBlockKind.reasoning => block.folded ? '▸ ' : '▾ ',
      ChatBlockKind.toolCall => '→ ',
      ChatBlockKind.notice =>
        block.notice == null ? '' : '${block.notice} · ',
      ChatBlockKind.user || ChatBlockKind.prose => '',
    };

/// [text] shortened to [max] columns, keeping its head and its tail: `head…tail`
/// totals at most [max]. Used for one-line subjects, whose tail carries meaning
/// even when the head is the familiar part.
String _truncateHeadTail(String text, int max) {
  if (plainWidth(text) <= max) return text;
  if (max <= 1) return _takeWidth(text, max < 0 ? 0 : max);
  final head = _takeWidth(text, (max * 3) ~/ 5);
  final tail = _takeWidthTail(text, max - plainWidth(head) - 1);
  return '$head…$tail';
}

/// The longest suffix of [text] fitting [width] columns.
String _takeWidthTail(String text, int width) {
  if (width <= 0) return '';
  var used = 0;
  var i = text.length;
  while (i > 0) {
    final prev = _prevRuneStart(text, i);
    final w = runeWidth(codePointAt(text, prev));
    if (used + w > width) break;
    used += w;
    i = prev;
  }
  return text.substring(i);
}

int _prevRuneStart(String text, int i) {
  final cu = text.codeUnitAt(i - 1);
  if (cu >= 0xdc00 && cu <= 0xdfff && i >= 2) {
    final hi = text.codeUnitAt(i - 2);
    if (hi >= 0xd800 && hi <= 0xdbff) return i - 2;
  }
  return i - 1;
}

/// The one-line form of a block: kind glyph, subject, and any trailing detail.
List<MarkdownRun> _headerRuns(ChatBlock block) {
  final runs = <MarkdownRun>[];
  switch (block.kind) {
    case ChatBlockKind.user:
      runs.add(MarkdownRun(block.subject, null));
    case ChatBlockKind.prose:
      break; // prose never reaches the one-line form
    case ChatBlockKind.reasoning:
      // Folded and expanded are told apart by the triangle alone, so the state
      // is legible without colour.
      runs.add(MarkdownRun(block.folded ? '▸ ' : '▾ ', null));
      runs.add(MarkdownRun(block.subject, null));
    case ChatBlockKind.toolCall:
      runs.add(const MarkdownRun('→ ', null));
      runs.add(MarkdownRun(block.subject, null));
    case ChatBlockKind.notice:
      if (block.notice != null) {
        runs.add(MarkdownRun('${block.notice} · ', null));
      }
      runs.add(MarkdownRun(block.subject, null));
  }
  if (block.status != null && block.status!.isNotEmpty) {
    runs.add(MarkdownRun('  ${block.status}', null));
  }
  return runs;
}

/// Prefix visual lines: [first] opens the block, [rest] continues it.
///
/// A blank line is left alone so a paragraph break reads as a gap — but the
/// *next* line after a gap takes [first] again, so a markdown block holding
/// several paragraphs labels each of them rather than only its first.
List<MarkdownLine> _prefixAll(
  List<MarkdownLine> lines,
  String first,
  String rest,
) {
  final out = <MarkdownLine>[];
  var freshBlock = true;
  for (final line in lines) {
    if (line.runs.isEmpty) {
      out.add(line);
      freshBlock = true;
      continue;
    }
    out.add(MarkdownLine(
      bar: line.bar,
      runs: [
        MarkdownRun(freshBlock ? first : rest, null),
        ...line.runs,
      ],
    ));
    freshBlock = false;
  }
  return out;
}

/// Split [lines] into visual lines that fit [width] columns.
///
/// Prose wraps at spaces so words survive; a row carrying a [MarkdownLine.bar]
/// (a fenced code block) wraps hard at the column, because breaking code on
/// spaces would misrepresent it. A single word longer than the line is broken
/// rather than allowed to overflow.
List<MarkdownLine> _wrap(List<MarkdownLine> lines, int width) {
  if (width <= 0) return lines;
  final out = <MarkdownLine>[];
  for (final line in lines) {
    if (line.isBlank) {
      out.add(const MarkdownLine.blank());
      continue;
    }
    final tokens = _tokenize(line.runs, hard: line.bar != null);
    var current = <MarkdownRun>[];
    var used = 0;
    for (final token in tokens) {
      final tokenWidth = plainWidth(token.text);
      if (used > 0 && used + tokenWidth > width) {
        out.add(MarkdownLine(bar: line.bar, runs: _trimTrailing(current)));
        current = <MarkdownRun>[];
        used = 0;
      }
      // A token wider than an empty line: hard-split it across rows.
      var text = token.text;
      while (plainWidth(text) > width) {
        final head = _takeWidth(text, width);
        out.add(MarkdownLine(bar: line.bar, runs: [MarkdownRun(head, token.code)]));
        text = text.substring(head.length);
      }
      if (text.isEmpty) continue;
      current.add(MarkdownRun(text, token.code));
      used += plainWidth(text);
    }
    if (current.isNotEmpty) {
      out.add(MarkdownLine(bar: line.bar, runs: _trimTrailing(current)));
    }
  }
  while (out.length > 1 && out.last.isBlank) {
    out.removeLast();
  }
  return out;
}

/// Split runs into wrap tokens. In soft mode each token keeps the spaces that
/// followed it, so trimming a wrapped line's tail does not glue words together
/// across the break. In hard mode there is one token per run, so the wrapper
/// breaks at the column instead.
List<MarkdownRun> _tokenize(List<MarkdownRun> runs, {required bool hard}) {
  final out = <MarkdownRun>[];
  for (final run in runs) {
    if (hard) {
      out.add(run);
      continue;
    }
    final text = run.text;
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x20) {
        out.add(MarkdownRun(text.substring(start, i + 1), run.code));
        start = i + 1;
      }
    }
    if (start < text.length) {
      out.add(MarkdownRun(text.substring(start), run.code));
    }
  }
  return out;
}

List<MarkdownRun> _trimTrailing(List<MarkdownRun> runs) {
  final out = List<MarkdownRun>.of(runs);
  while (out.isNotEmpty) {
    final last = out.last;
    final trimmed = last.text.replaceFirst(RegExp(r' +$'), '');
    if (trimmed == last.text) break;
    if (trimmed.isEmpty) {
      out.removeLast();
      continue;
    }
    out[out.length - 1] = MarkdownRun(trimmed, last.code);
    break;
  }
  return out;
}

/// The longest prefix of [text] fitting [width] columns, never splitting a
/// surrogate pair. Always consumes at least one rune, so a zero-width-only
/// remainder cannot loop forever.
String _takeWidth(String text, int width) {
  var used = 0;
  var i = 0;
  while (i < text.length) {
    final size = runeSizeAt(text, i);
    final w = runeWidth(codePointAt(text, i));
    if (used + w > width) break;
    used += w;
    i += size;
  }
  return i == 0 ? text.substring(0, runeSizeAt(text, 0)) : text.substring(0, i);
}

/// Truncate [label] to [width] columns, marking the cut.
String _truncateToWidth(String label, int width) {
  final head = _takeWidth(label, width);
  if (head.length >= label.length) return head;
  return width <= 1 ? head : '${_takeWidth(label, width - 1)}…';
}

/// Plain content lines from [text] — one visual line per source line.
List<MarkdownLine> plainLines(String text) => [
      for (final line in text.split('\n'))
        line.isEmpty
            ? const MarkdownLine.blank()
            : MarkdownLine(runs: [MarkdownRun(line, null)]),
    ];

/// The body lines of a block, for the too-narrow fallback where there is no
/// room for a gutter.
List<MarkdownLine> _bodyLines(ChatBlock block) => block.body.isEmpty
    ? [MarkdownLine(runs: [MarkdownRun(block.subject, null)])]
    : block.body;
