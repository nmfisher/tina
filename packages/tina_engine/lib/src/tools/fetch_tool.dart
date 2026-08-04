import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../llm/http.dart';
import 'tool.dart';

final _log = Logger('tina.tools.fetch');

/// Convert an HTML string to a focused markdown extract: headings, links,
/// code, lists, emphasis, blockquotes, images. Scripts, styles and other
/// non-content markup are dropped.
///
/// Deliberately not a full HTML→markdown transpiler — just enough structure
/// for the model to read a fetched page (docs, issues, changelogs). Extracted
/// as a pure function so it is unit-testable without any network.
String htmlToMarkdown(String html) {
  final doc = html_parser.parse(html);
  final walker = _Walker();
  for (final node in doc.nodes) {
    walker.visit(node);
  }
  final collapsed = walker.out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return collapsed.trim();
}

/// Recursive HTML→markdown walker. Block elements open with a blank-line
/// separator; inline elements (a, code, em, strong, img, br, text) are composed
/// into runs.
class _Walker {
  final StringBuffer out = StringBuffer();
  int _listDepth = 0;
  bool _ordered = false;
  int _counter = 1;

  void visit(dom.Node node) {
    if (node is dom.Text) {
      _emit(node.text);
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName?.toLowerCase();
    if (tag == null) {
      // Element with no recognizable name (e.g. an unknown namespace):
      // recurse so we don't drop the text inside it.
      for (final child in node.nodes) {
        visit(child);
      }
      return;
    }

    // Non-content: drop entirely.
    switch (tag) {
      case 'script':
      case 'style':
      case 'noscript':
      case 'head':
      case 'meta':
      case 'link':
      case 'title':
        return;
    }

    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        _blockStart();
        final level = int.parse(tag.substring(1));
        out.write('${'#' * level} ${inlineText(node)}');
      case 'p':
        _blockStart();
        out.write(inlineText(node));
      case 'br':
        out.write('\n');
      case 'hr':
        _blockStart();
        out.write('---');
      case 'pre':
        _blockStart();
        final code = node.text;
        final lang = _codeLanguage(node);
        out.writeln('```${lang}');
        out.write(code);
        if (!code.endsWith('\n')) out.writeln();
        out.write('```');
      case 'blockquote':
        _blockStart();
        final inner = inlineText(node).trim();
        for (final line in inner.split('\n')) {
          out.writeln('> $line');
        }
      case 'ul':
        _listDepth++;
        final prev = _ordered;
        _ordered = false;
        for (final child in node.nodes) {
          visit(child);
        }
        _ordered = prev;
        _listDepth--;
      case 'ol':
        _listDepth++;
        final prev = _ordered;
        final prevCount = _counter;
        _ordered = true;
        _counter = 1;
        for (final child in node.nodes) {
          visit(child);
        }
        _ordered = prev;
        _counter = prevCount;
        _listDepth--;
      case 'li':
        _blockStart();
        final indent = '  ' * (_listDepth - 1).clamp(0, 8);
        final marker = _ordered ? '${_counter}. ' : '- ';
        _counter++;
        out.write('$indent$marker${inlineText(node).trim()}');
      case 'table':
        _listDepth++;
        for (final child in node.nodes) {
          visit(child);
        }
        _listDepth--;
      case 'tr':
        _blockStart();
        final cells = <String>[];
        for (final cell in node.nodes) {
          if (cell is dom.Element &&
              (cell.localName == 'td' || cell.localName == 'th')) {
            cells.add(inlineText(cell).trim());
          }
        }
        out.write(cells.join(' | '));
      case 'img':
        final alt = node.attributes['alt'] ?? '';
        final src = node.attributes['src'] ?? '';
        if (src.isNotEmpty) {
          _emit('![$alt]($src)');
        }
      default:
        // Any other container (div, section, article, span, nav, table body…):
        // recurse so we don't lose the text inside.
        for (final child in node.nodes) {
          visit(child);
        }
    }
  }

  /// Collects the inline markdown of [element]'s children.
  String inlineText(dom.Element element) {
    final sb = StringBuffer();
    for (final child in element.nodes) {
      sb.write(_inline(child));
    }
    return sb.toString();
  }

  String _inline(dom.Node node) {
    if (node is dom.Text) {
      return _collapseSpace(node.text);
    }
    if (node is! dom.Element) return '';
    final tag = node.localName?.toLowerCase();
    switch (tag) {
      case 'script':
      case 'style':
      case 'noscript':
        return '';
      case 'br':
        return '\n';
      case 'img':
        final alt = node.attributes['alt'] ?? '';
        final src = node.attributes['src'] ?? '';
        return src.isNotEmpty ? '![$alt]($src)' : '';
      case 'code':
        return '`${node.text}`';
      case 'strong':
      case 'b':
        return '**${inlineText(node)}**';
      case 'em':
      case 'i':
        return '*${inlineText(node)}*';
      case 'a':
        final href = node.attributes['href'] ?? '';
        final text = inlineText(node);
        if (href.isEmpty || href == '#') return text;
        return '[$text]($href)';
      default:
        return inlineText(node);
    }
  }

  /// Writes inline text, collapsing surrounding whitespace into the running
  /// output so block/inline boundaries don't accumulate stray spaces.
  void _emit(String text) {
    out.write(_collapseSpace(text));
  }

  void _blockStart() {
    if (out.isEmpty) return;
    // Ensure exactly one blank line between blocks.
    final s = out.toString();
    if (s.endsWith('\n\n')) return;
    if (s.endsWith('\n')) {
      out.writeln();
    } else {
      out.writeln();
      out.writeln();
    }
  }

  /// Guesses a fenced-code language from a `<pre>`'s child `<code>` class, e.g.
  /// `class="language-dart"` or `class="lang-js"`.
  String _codeLanguage(dom.Element pre) {
    final code = pre.nodes.whereType<dom.Element>().firstWhere(
          (e) => e.localName == 'code',
          orElse: () => pre,
        );
    for (final cls in code.classes) {
      if (cls.startsWith('language-')) return cls.substring('language-'.length);
      if (cls.startsWith('lang-')) return cls.substring('lang-'.length);
    }
    return '';
  }
}

/// Collapses each run of whitespace (including newlines) to a single space.
String _collapseSpace(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

/// Fetch a URL and return its content as markdown. An agent-invoked tool — the
/// model calls it to read a full page (docs, issue, changelog) that a
/// `web_search` snippet is too short to convey.
///
/// Read-only GET, no API key, so it is always registered (the model can already
/// reach arbitrary URLs via `bash`; this is the structured, read-only path).
/// Only `http`/`https` schemes are allowed.
class FetchTool implements Tool {
  static const int defaultMaxChars = 20000;
  static const int hardMaxChars = 100000;

  final http.Client _client;
  final int maxChars;

  FetchTool({
    http.Client? client,
    this.maxChars = defaultMaxChars,
  }) : _client = client ?? http.Client();

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'fetch',
        description:
            'Fetch a URL and return its content as markdown. Use to read a full '
            'web page — docs, issue, changelog, API reference — when a '
            '`web_search` snippet is too short. Only http/https URLs. Returns '
            'the page converted to markdown (headings, links, code, lists).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': 'The http or https URL to fetch.',
            },
            'max_chars': {
              'type': 'integer',
              'description':
                  'Maximum characters to return (truncates when exceeded). '
                  'Defaults to $defaultMaxChars.',
            },
          },
          'required': ['url'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final url = input['url'] as String?;
    if (url == null || url.trim().isEmpty) {
      return ToolResult.error('url is required');
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return ToolResult.error('url must be a valid http or https URL');
    }

    final requested = input['max_chars'] as int? ?? maxChars;
    final capped = requested.clamp(1, hardMaxChars);

    http.Request build() {
      final r = http.Request('GET', uri);
      r.headers.addAll({
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'User-Agent': 'tina/1.0',
      });
      return r;
    }

    String body;
    String? contentType;
    try {
      final resp = await sendWithRetry(_client, build);
      body = await resp.stream.bytesToString();
      contentType = resp.headers['content-type'];
      if (resp.statusCode != 200) {
        return ToolResult.error(
          'fetch failed (${resp.statusCode}): ${body.length > 200 ? "${body.substring(0, 200)}…" : body}',
        );
      }
    } catch (e) {
      _log.warning('fetch failed: $e');
      return ToolResult.error('fetch failed: $e');
    }

    final isHtml = contentType?.toLowerCase().contains('html') ?? true;
    final text = isHtml ? htmlToMarkdown(body) : body;
    return text.length <= capped
        ? ToolResult(text)
        : ToolResult('${text.substring(0, capped)}\n\n... (truncated)');
  }

  /// Visible for tests.
  // ignore: unused_element
  void _close() => _client.close();
}
