import 'package:markdown/markdown.dart' as md;
import 'package:tina_console/tina_console.dart';

/// Markdown → styled chat lines (tin-g7rk).
///
/// A pure function layer between the agent sink and the chat region: the
/// [MarkdownStreamSplitter] carves streamed prose into closed blocks, and
/// [renderMarkdown] parses each block with the `markdown` package and maps
/// its AST onto [MarkdownLine]s — runs of text carrying inline SGR codes,
/// optionally over a row-level bar style (fenced code). [serializeLine] then
/// turns a line into the string the sink writes: SGR-embedded when the
/// surface renders color, plain when it does not.
///
/// The renderer never touches a [Screen] — every styling decision resolves
/// through [MarkdownStyle], so unit tests assert on runs, not on terminal
/// bytes. All codes must stay inside the vocabulary `applySgrCode`
/// (styled_text.dart) understands; the ChatTheme tests pin that.

/// Inline/row style codes for rendering agent markdown, resolved from the
/// chat theme. [base] is the agent-prose row style the sink opens around
/// rendered text; the others map 1:1 to markdown constructs.
class MarkdownStyle {
  /// Agent prose row style (ChatTheme.agentText). Re-established after every
  /// inline-styled run so an embedded SGR never leaks past its span.
  final String base;

  final String header;
  final String inlineCode;

  /// Row style for fenced/indented code blocks. Must set a background so
  /// the chat region paints it as a solid bar.
  final String codeBlock;
  final String link;
  final String dim;

  const MarkdownStyle({
    this.base = '39',
    this.header = '1',
    this.inlineCode = '100',
    this.codeBlock = '100',
    this.link = '4;36',
    this.dim = '2',
  });

  factory MarkdownStyle.fromChatTheme(ChatTheme chat) => MarkdownStyle(
        base: chat.agentText,
        header: chat.header,
        inlineCode: chat.inlineCode,
        codeBlock: chat.codeBlock,
        link: chat.link,
        dim: chat.dim,
      );
}

/// One span of text; [code] is an inline SGR string layered over the row's
/// base style, or null for base-styled prose.
class MarkdownRun {
  final String text;
  final String? code;

  const MarkdownRun(this.text, this.code);
}

/// One rendered visual line: [runs] laid out left to right, optionally over
/// a row-level [bar] style. An empty [runs] list is a blank line.
class MarkdownLine {
  final String? bar;
  final List<MarkdownRun> runs;

  const MarkdownLine({this.bar, this.runs = const []});

  const MarkdownLine.blank()
      : bar = null,
        runs = const [];

  bool get isBlank => bar == null && runs.every((r) => r.text.isEmpty);
}

/// Render one closed block of markdown source into styled lines, blank-line
/// separated at the top level. Content is never dropped: unknown constructs
/// fall back to their text content.
List<MarkdownLine> renderMarkdown(String source, MarkdownStyle style) {
  final nodes = md.Document().parse(source);
  final out = <MarkdownLine>[];
  for (final node in nodes) {
    if (out.isNotEmpty) out.add(const MarkdownLine.blank());
    out.addAll(_renderNode(node, style, indent: ''));
  }
  // Drop a trailing blank so the caller's own turn terminator provides the
  // final break.
  while (out.isNotEmpty && out.last.isBlank) {
    out.removeLast();
  }
  return out;
}

List<MarkdownLine> _renderNode(md.Node node, MarkdownStyle style,
    {required String indent}) {
  if (node is md.Text) {
    // Bare text at block level (rare): treat as a paragraph.
    return _linesFromRuns([MarkdownRun(node.text, null)], indent: indent);
  }
  if (node is! md.Element) {
    return const [];
  }
  switch (node.tag) {
    case 'p':
      return _linesFromRuns(_inlineRuns(node.children, style),
          indent: indent);
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      return [
        MarkdownLine(
            runs: [MarkdownRun(indent + node.textContent, style.header)]),
      ];
    case 'blockquote':
      final out = <MarkdownLine>[];
      for (final child in node.children ?? const <md.Node>[]) {
        if (out.isNotEmpty) out.add(const MarkdownLine.blank());
        for (final line in _renderNode(child, style, indent: indent)) {
          out.add(_prefixLine(line, MarkdownRun('│ ', style.dim)));
        }
      }
      return out;
    case 'ul':
    case 'ol':
      return _renderList(node, style, indent: indent);
    case 'pre':
      return _renderCodeBlock(node, style);
    case 'hr':
      return [
        MarkdownLine(runs: [MarkdownRun('${indent}───', style.dim)]),
      ];
    default:
      // Unknown block (html fragments, extension constructs we do not
      // enable): recurse so text survives, unstyled.
      final out = <MarkdownLine>[];
      for (final child in node.children ?? const <md.Node>[]) {
        if (out.isNotEmpty) out.add(const MarkdownLine.blank());
        out.addAll(_renderNode(child, style, indent: indent));
      }
      if (out.isEmpty && node.textContent.isNotEmpty) {
        out.addAll(_linesFromRuns(
            [MarkdownRun(node.textContent, null)], indent: indent));
      }
      return out;
  }
}

/// Paragraph/list-item body: inline runs split at hard/soft breaks into
/// visual lines, each prefixed with [indent] when set.
List<MarkdownLine> _linesFromRuns(List<MarkdownRun> runs,
    {required String indent}) {
  final lines = _splitRunsAtBreaks(runs);
  if (lines.isEmpty) return const [];
  return [
    for (final lineRuns in lines)
      MarkdownLine(runs: [
        if (indent.isNotEmpty) MarkdownRun(indent, null),
        ...lineRuns,
      ]),
  ];
}

/// Walk inline nodes, mapping emphasis/code/links to styled runs. [bits]
/// accumulates bold/italic across nesting (`***x***`).
List<MarkdownRun> _inlineRuns(List<md.Node>? nodes, MarkdownStyle style,
    {int bits = 0}) {
  if (nodes == null) return const [];
  final out = <MarkdownRun>[];
  for (final node in nodes) {
    if (node is md.Text) {
      out.add(MarkdownRun(_decodeEntities(node.text), _bitsCode(bits)));
      continue;
    }
    if (node is! md.Element) continue;
    switch (node.tag) {
      case 'strong':
        out.addAll(_inlineRuns(node.children, style, bits: bits | 1));
      case 'em':
        out.addAll(_inlineRuns(node.children, style, bits: bits | 2));
      case 'code':
        // The parser entity-encodes code-span content once (it targets HTML
        // output); a single decode restores the source text exactly.
        out.add(MarkdownRun(_decodeEntities(node.textContent), style.inlineCode));
      case 'a':
        final href = node.attributes['href'] ?? '';
        final label = node.textContent;
        if (href.isEmpty || href == label) {
          out.add(MarkdownRun(label, style.link));
        } else {
          out
            ..add(MarkdownRun(label, style.link))
            ..add(MarkdownRun(' ($href)', style.dim));
        }
      case 'img':
        final src = node.attributes['src'] ?? '';
        final alt = node.attributes['alt'] ?? node.textContent;
        out
          ..add(MarkdownRun(alt, style.link))
          ..add(MarkdownRun(' ($src)', style.dim));
      case 'br':
        out.add(const MarkdownRun('\n', null));
      default:
        // Unknown inline: recurse unstyled so content survives.
        out.addAll(_inlineRuns(node.children, style, bits: bits));
    }
  }
  return _coalesce(out);
}

/// Merge adjacent runs carrying the same code, so entity/escape decoding
/// (which splits a paragraph into several Text nodes) does not fragment
/// the run list — one styled span, one run.
List<MarkdownRun> _coalesce(List<MarkdownRun> runs) {
  final out = <MarkdownRun>[];
  for (final run in runs) {
    if (out.isNotEmpty && out.last.code == run.code) {
      out[out.length - 1] = MarkdownRun(out.last.text + run.text, run.code);
    } else {
      out.add(run);
    }
  }
  return out;
}

final _entityRe = RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);');

const _namedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ', // a non-breaking space in a terminal cell is just a space
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'copy': '©',
};

/// Decode HTML entities in prose text. The markdown package leaves them
/// literal in Text nodes (its HTML renderer does the decoding); agents emit
/// `&amp;`/`&lt;` constantly, so rendered prose decodes the common set.
/// Code spans are passed through undecoded (CommonMark) — they never come
/// through here.
String _decodeEntities(String text) {
  if (!text.contains('&')) return text;
  return text.replaceAllMapped(_entityRe, (m) {
    final body = m.group(1)!;
    if (body.startsWith('#')) {
      final radix = body.startsWith('#x') || body.startsWith('#X') ? 16 : 10;
      final code =
          int.tryParse(body.substring(radix == 16 ? 2 : 1), radix: radix);
      if (code == null || code == 0 || code > 0x10FFFF) return m.group(0)!;
      try {
        return String.fromCharCode(code);
      } on ArgumentError {
        return m.group(0)!; // lone surrogate — keep the source form
      }
    }
    return _namedEntities[body] ?? m.group(0)!;
  });
}

String? _bitsCode(int bits) {
  if (bits == 0) return null;
  return [
    if (bits & 1 != 0) '1',
    if (bits & 2 != 0) '3',
  ].join(';');
}

/// Split runs at '\n' boundaries into per-line run lists, dropping the
/// newline itself (the caller writes rows).
List<List<MarkdownRun>> _splitRunsAtBreaks(List<MarkdownRun> runs) {
  final out = <List<MarkdownRun>>[[]];
  for (final run in runs) {
    var text = run.text;
    while (true) {
      final nl = text.indexOf('\n');
      if (nl < 0) break;
      if (nl > 0) out.last.add(MarkdownRun(text.substring(0, nl), run.code));
      out.add([]);
      text = text.substring(nl + 1);
    }
    if (text.isNotEmpty) out.last.add(MarkdownRun(text, run.code));
  }
  // A trailing break does not open a line of its own.
  if (out.length > 1 && out.last.isEmpty) out.removeLast();
  return out;
}

MarkdownLine _prefixLine(MarkdownLine line, MarkdownRun prefix) =>
    MarkdownLine(
      bar: line.bar,
      runs: line.runs.isEmpty ? [prefix] : [prefix, ...line.runs],
    );

List<MarkdownLine> _renderList(md.Element list, MarkdownStyle style,
    {required String indent}) {
  final out = <MarkdownLine>[];
  final ordered = list.tag == 'ol';
  final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
  var n = start;
  for (final item in list.children ?? const <md.Node>[]) {
    if (item is! md.Element) continue;
    if (item.tag == 'ul' || item.tag == 'ol') {
      // A nested list directly under the list (no li wrapper) — tolerated.
      out.addAll(_renderList(item, style, indent: indent));
      continue;
    }
    if (item.tag != 'li') continue;
    final marker = ordered ? '$n. ' : '• ';
    n++;
    final markerRun = MarkdownRun(indent + marker, null);
    // An li's inline content may be bare (tight list) or wrapped in p
    // (loose list); nested lists are separate children.
    final inlineNodes = <md.Node>[];
    md.Element? subList;
    for (final child in item.children ?? const <md.Node>[]) {
      if (child is md.Element && (child.tag == 'ul' || child.tag == 'ol')) {
        subList = child;
      } else if (child is md.Element && child.tag == 'p') {
        inlineNodes.addAll(child.children ?? const <md.Node>[]);
      } else {
        inlineNodes.add(child);
      }
    }
    final itemLines =
        _splitRunsAtBreaks(_inlineRuns(inlineNodes, style));
    if (itemLines.isEmpty) {
      out.add(MarkdownLine(runs: [markerRun]));
    }
    for (var i = 0; i < itemLines.length; i++) {
      out.add(MarkdownLine(runs: [
        if (i == 0)
          markerRun
        else
          MarkdownRun(' ' * markerRun.text.length, null),
        ...itemLines[i],
      ]));
    }
    if (subList != null) {
      out.addAll(_renderList(subList, style, indent: '$indent  '));
    }
  }
  return out;
}

List<MarkdownLine> _renderCodeBlock(md.Element pre, MarkdownStyle style) {
  // pre > code > Text; the text carries a leading newline from the fence,
  // and entity-encoded content (the parser targets HTML output) — one
  // decode restores the source.
  var text = _decodeEntities(pre.textContent);
  if (text.startsWith('\n')) text = text.substring(1);
  final lines = text.split('\n');
  // The fence's final newline produces one trailing empty segment — drop it.
  if (lines.length > 1 && lines.last.isEmpty) {
    lines.removeLast();
  }
  return [
    for (final line in lines)
      MarkdownLine(
        bar: style.codeBlock,
        runs: line.isEmpty ? const [] : [MarkdownRun(line, null)],
      ),
  ];
}

/// A line assembled for direct writing: [bar] is the row-level style to
/// open (or null for plain rows); [text] is the serialized run text.
class SerializedLine {
  final String? bar;
  final String text;

  const SerializedLine(this.text, this.bar);
}

/// Turn a rendered line into what the sink writes. With [styled] off (no
/// color / passthrough surfaces) the line degrades to its plain text —
/// block structure survives, inline styles vanish.
SerializedLine serializeLine(MarkdownLine line, MarkdownStyle style,
    {required bool styled}) {
  if (!styled) {
    return SerializedLine(line.runs.map((r) => r.text).join(), line.bar);
  }
  final sb = StringBuffer();
  for (final run in line.runs) {
    if (run.code == null) {
      sb.write(run.text);
      continue;
    }
    // Open on top of the row's base state, then close back to it: a bare
    // \x1b[0m would strand later prose on the terminal default instead of
    // the theme's agent colour.
    sb
      ..write('\x1b[${run.code}m')
      ..write(run.text)
      ..write('\x1b[0m\x1b[${style.base}m');
  }
  return SerializedLine(sb.toString(), line.bar);
}

/// Carves streamed prose into closed markdown blocks (tin-g7rk streaming
/// contract). [push] accumulates deltas and returns every block that has
/// closed: one ended by a blank line outside a fenced code block, or one
/// ending at a closing fence line. [flush] hands back the open remainder
/// for rendering at prose end. Pure — the sink owns all region calls.
class MarkdownStreamSplitter {
  final StringBuffer _pending = StringBuffer();

  /// Feed a streamed delta; returns source text of every newly closed block,
  /// in order. Blank-only chunks are consumed and not returned.
  List<String> push(String delta) {
    _pending.write(delta);
    final out = <String>[];
    while (true) {
      final chunk = _extractOne();
      if (chunk == null) break;
      if (chunk.trim().isNotEmpty) out.add(chunk);
    }
    return out;
  }

  /// Drain the open remainder (prose ended). Empty string when nothing is
  /// held.
  String flush() {
    final rest = _pending.toString();
    _pending.clear();
    return rest;
  }

  /// Whether a block is currently held back (for diagnostics/tests).
  bool get hasPending => _pending.isNotEmpty;

  /// Pull the first closed block out of the pending buffer, or null when no
  /// complete block boundary exists yet. Only whole (newline-terminated)
  /// lines are considered: a held block must not render before its last
  /// line is known complete.
  String? _extractOne() {
    final text = _pending.toString();
    var fence = false;
    var fenceCh = ''; // '`' or '~' of the open fence
    var lineStart = 0;
    while (lineStart < text.length) {
      final nl = text.indexOf('\n', lineStart);
      if (nl < 0) return null; // final line still growing
      final line = text.substring(lineStart, nl);
      if (fence) {
        if (_isFenceClose(line, fenceCh)) {
          // Boundary right after the closing fence line.
          final chunk = text.substring(0, nl + 1);
          _pending
            ..clear()
            ..write(text.substring(nl + 1));
          return chunk;
        }
      } else {
        if (line.trim().isEmpty) {
          // Boundary just before this blank line; consume it and any run of
          // blanks so blocks do not stack empty chunks.
          final chunk = text.substring(0, lineStart);
          var consume = nl + 1;
          while (consume < text.length) {
            final nextNl = text.indexOf('\n', consume);
            if (nextNl < 0) break;
            if (text.substring(consume, nextNl).trim().isNotEmpty) break;
            consume = nextNl + 1;
          }
          _pending
            ..clear()
            ..write(text.substring(consume));
          return chunk;
        }
        final open = _fenceOpen(line);
        if (open != null) {
          fence = true;
          fenceCh = open;
        }
      }
      lineStart = nl + 1;
    }
    return null;
  }

  /// The fence character of a line that opens a fenced block, or null.
  String? _fenceOpen(String line) {
    final indent = line.length - line.trimLeft().length;
    if (indent > 3) return null;
    final s = line.substring(indent);
    if (s.startsWith('```')) return '`';
    if (s.startsWith('~~~')) return '~';
    return null;
  }

  bool _isFenceClose(String line, String fenceCh) {
    final s = line.trim();
    if (s.length < 3) return false;
    for (var i = 0; i < s.length; i++) {
      if (s[i] != fenceCh) return false;
    }
    return true;
  }
}
