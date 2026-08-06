import 'graph.dart';

/// Thrown when DOT source is outside the supported subset or is malformed.
class DotParseError implements Exception {
  final String message;
  DotParseError(this.message);
  @override
  String toString() => 'DotParseError: $message';
}

/// Parse a DOT `digraph` into a [Graph]. Accepts the attractor subset: one
/// directed graph, `graph`/`node`/`edge` attribute blocks, node and edge
/// statements, chained edges (`A -> B -> C`), `//` and `/* */` comments, and
/// quoted or bare attribute values.
Graph parseDot(String source) => _Parser(_tokenize(source)).parse();

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

enum _TokType { ident, string, number, duration, lbrace, rbrace, lbrack, rbrack, comma, semi, eq, arrow, dot }

class _Tok {
  final _TokType type;
  final String text;
  _Tok(this.type, this.text);
}

List<_Tok> _tokenize(String src) {
  final toks = <_Tok>[];
  var i = 0;
  String peek([int o = 0]) => (i + o < src.length) ? src[i + o] : '';
  while (i < src.length) {
    final c = src[i];
    // Whitespace.
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
      continue;
    }
    // Line comment.
    if (c == '/' && peek(1) == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    // Block comment.
    if (c == '/' && peek(1) == '*') {
      i += 2;
      while (i < src.length && !(src[i] == '*' && peek(1) == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    // String.
    if (c == '"') {
      final buf = StringBuffer();
      i++;
      while (i < src.length && src[i] != '"') {
        if (src[i] == r'\' && i + 1 < src.length) {
          final n = src[i + 1];
          buf.write(n == 'n'
              ? '\n'
              : n == 't'
                  ? '\t'
                  : n); // \" \\ etc. — keep the escaped char verbatim.
          i += 2;
        } else {
          buf.write(src[i]);
          i++;
        }
      }
      i++; // closing quote
      toks.add(_Tok(_TokType.string, buf.toString()));
      continue;
    }
    // Arrow or dash.
    if (c == '-' && peek(1) == '>') {
      toks.add(_Tok(_TokType.arrow, '->'));
      i += 2;
      continue;
    }
    if (c == '-') {
      // Could be a negative number or a stray dash (undirected '--' is rejected).
      if (peek(1) == '-') {
        throw DotParseError('undirected edge "--" is not supported '
            '(attractor uses directed "->" only)');
      }
      // otherwise fall through to number handling below (negative).
    }
    // Punctuation.
    switch (c) {
      case '{':
        toks.add(_Tok(_TokType.lbrace, c));
        i++;
        continue;
      case '}':
        toks.add(_Tok(_TokType.rbrace, c));
        i++;
        continue;
      case '[':
        toks.add(_Tok(_TokType.lbrack, c));
        i++;
        continue;
      case ']':
        toks.add(_Tok(_TokType.rbrack, c));
        i++;
        continue;
      case ',':
        toks.add(_Tok(_TokType.comma, c));
        i++;
        continue;
      case ';':
        toks.add(_Tok(_TokType.semi, c));
        i++;
        continue;
      case '=':
        toks.add(_Tok(_TokType.eq, c));
        i++;
        continue;
      case '.':
        toks.add(_Tok(_TokType.dot, c));
        i++;
        continue;
    }
    // Number (optionally negative, with fractional part) + optional duration unit.
    if (c == '-' || _isDigit(c)) {
      final start = i;
      if (c == '-') i++;
      while (i < src.length && _isDigit(src[i])) {
        i++;
      }
      var isFloat = false;
      if (i < src.length && src[i] == '.' && _isDigit(peek(1))) {
        isFloat = true;
        i++; // dot
        while (i < src.length && _isDigit(src[i])) {
          i++;
        }
      }
      final numStr = src.substring(start, i);
      // Duration unit?
      if (i < src.length && _isAlpha(src[i])) {
        final unitStart = i;
        while (i < src.length && _isAlpha(src[i])) {
          i++;
        }
        final unit = src.substring(unitStart, i);
        if (const {'ms', 's', 'm', 'h', 'd'}.contains(unit)) {
          toks.add(_Tok(_TokType.duration, '$numStr$unit'));
          continue;
        } else {
          // Not a unit — a bare value can't follow a number directly; treat the
          // whole thing as a bare-ish duration string to be safe.
          toks.add(_Tok(_TokType.duration, '$numStr$unit'));
          continue;
        }
      }
      toks.add(_Tok(
          isFloat ? _TokType.number : _TokType.number, numStr));
      continue;
    }
    // Bareword: [A-Za-z_][A-Za-z0-9_:.-]*  (covers shape names, true/false,
    // dotted keys/values like stack.child_dotfile, model ids like gpt-4).
    if (_isBareStart(c)) {
      final start = i;
      i++;
      while (i < src.length && _isBarePart(src[i])) {
        i++;
      }
      toks.add(_Tok(_TokType.ident, src.substring(start, i)));
      continue;
    }
    throw DotParseError('unexpected character "${String.fromCharCode(c.codeUnitAt(0) & 0xFF)}" '
        'at offset $i');
  }
  return toks;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
bool _isAlpha(String c) =>
    (c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90) ||
    (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122) ||
    c == '_';
bool _isBareStart(String c) =>
    _isAlpha(c);
bool _isBarePart(String c) =>
    _isAlpha(c) || _isDigit(c) || c == '_' || c == '.' || c == ':' || c == '-';

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

class _Parser {
  final List<_Tok> toks;
  int pos = 0;

  // Positional default-attr scopes (graph-level node/edge defaults).
  final Map<String, AttrValue> _nodeDefaults = {};
  final Map<String, AttrValue> _edgeDefaults = {};

  _Parser(this.toks);

  _Tok? get _peek => pos < toks.length ? toks[pos] : null;

  bool _is(_TokType t) => _peek?.type == t;

  _Tok _next() {
    if (pos >= toks.length) {
      throw DotParseError('unexpected end of input');
    }
    return toks[pos++];
  }

  _Tok _expect(_TokType t, [String? what]) {
    final tk = _peek;
    if (tk == null || tk.type != t) {
      throw DotParseError('expected ${what ?? t.name}, '
          'got ${tk == null ? 'end of input' : '"${tk.text}"'}');
    }
    return _next();
  }

  Graph parse() {
    final kw = _peek;
    if (kw == null || kw.type != _TokType.ident || kw.text != 'digraph') {
      throw DotParseError('expected "digraph", '
          'got ${kw == null ? 'end of input' : '"${kw.text}"'}');
    }
    _next();
    final name = _is(_TokType.ident) ? _next().text : 'pipeline';
    _expect(_TokType.lbrace, '"{"');

    final attrs = <String, AttrValue>{};
    final nodes = <String, PipelineNode>{};
    final edges = <PipelineEdge>[];

    while (!_is(_TokType.rbrace) && _peek != null) {
      _statement(attrs, nodes, edges);
    }
    _expect(_TokType.rbrace, '"}"');

    return Graph(name: name, attrs: attrs, nodes: nodes, edges: edges);
  }

  void _statement(
    Map<String, AttrValue> graphAttrs,
    Map<String, PipelineNode> nodes,
    List<PipelineEdge> edges,
  ) {
    final tk = _peek!;
    if (tk.type == _TokType.ident) {
      switch (tk.text) {
        case 'graph':
          _next();
          _mergeInto(graphAttrs, _attrBlock());
          _optionalSemi();
          return;
        case 'node':
          _next();
          _mergeInto(_nodeDefaults, _attrBlock());
          _optionalSemi();
          return;
        case 'edge':
          _next();
          _mergeInto(_edgeDefaults, _attrBlock());
          _optionalSemi();
          return;
        case 'subgraph':
          _next();
          if (_is(_TokType.ident)) _next(); // optional id
          _expect(_TokType.lbrace, '"{"');
          // Flatten: statements in the subgraph apply to the same scopes.
          while (!_is(_TokType.rbrace) && _peek != null) {
            _statement(graphAttrs, nodes, edges);
          }
          _expect(_TokType.rbrace, '"}"');
          _optionalSemi();
          return;
      }
    }

    // Either an edge statement (ID '->' ...), a node statement (ID '['?),
    // or a top-level graph attr decl (ID '=' value).
    final firstId = _qualifiedId();
    if (_is(_TokType.arrow)) {
      _edgeStatement(firstId, nodes, edges);
    } else if (_is(_TokType.eq)) {
      // graph-level key = value
      _next();
      graphAttrs[firstId] = _value();
      _optionalSemi();
    } else {
      // node statement (optional attr block)
      final attrs = <String, AttrValue>{};
      if (_is(_TokType.lbrack)) {
        _mergeInto(attrs, _attrBlock());
      }
      _ensureNode(nodes, firstId, attrs);
      _optionalSemi();
    }
  }

  void _edgeStatement(
    String firstId,
    Map<String, PipelineNode> nodes,
    List<PipelineEdge> edges,
  ) {
    // firstId '->' id ('->' id)* [attrs]
    final chain = <String>[firstId];
    while (_is(_TokType.arrow)) {
      _next();
      chain.add(_qualifiedId());
    }
    final edgeAttrs = <String, AttrValue>{};
    if (_is(_TokType.lbrack)) {
      _mergeInto(edgeAttrs, _attrBlock());
    }
    for (var i = 0; i < chain.length - 1; i++) {
      final from = chain[i];
      final to = chain[i + 1];
      _ensureNode(nodes, from, null);
      _ensureNode(nodes, to, null);
      edges.add(_makeEdge(from, to, edgeAttrs));
    }
    _optionalSemi();
  }

  PipelineEdge _makeEdge(String from, String to, Map<String, AttrValue> attrs) {
    final merged = <String, AttrValue>{..._edgeDefaults, ...attrs};
    return PipelineEdge(
      from: from,
      to: to,
      label: (merged['label'] as String?) ?? '',
      condition: (merged['condition'] as String?) ?? '',
      weight: _asInt(merged['weight'], 0),
      attrs: merged,
    );
  }

  void _ensureNode(
      Map<String, PipelineNode> nodes, String id, Map<String, AttrValue>? attrs) {
    final existing = nodes[id];
    if (existing == null) {
      final base = <String, AttrValue>{..._nodeDefaults, ...?attrs};
      nodes[id] = PipelineNode(id: id, attrs: base);
    } else if (attrs != null) {
      // Re-declaration overlays explicit attrs on top of what's there.
      existing.attrs.addAll(attrs);
    }
  }

  // -- Attribute blocks -----------------------------------------------------

  Map<String, AttrValue> _attrBlock() {
    _expect(_TokType.lbrack, '"["');
    final attrs = <String, AttrValue>{};
    while (!_is(_TokType.rbrack) && _peek != null) {
      final key = _qualifiedId();
      _expect(_TokType.eq, '"="');
      attrs[key] = _value();
      if (_is(_TokType.comma) || _is(_TokType.semi)) {
        _next();
      }
    }
    _expect(_TokType.rbrack, '"]"');
    return attrs;
  }

  /// A key, possibly dotted (`stack.child_dotfile`). Bareword tokens carry
  /// their own dots already, but a token-level dot also joins.
  String _qualifiedId() {
    final first = _expect(_TokType.ident, 'an identifier');
    var result = first.text;
    // Bareword tokenizer may have absorbed dots; if not, join explicit dots.
    while (_is(_TokType.dot)) {
      _next();
      final next = _expect(_TokType.ident, 'an identifier after "."');
      result = '$result.${next.text}';
    }
    return result;
  }

  AttrValue _value() {
    final tk = _next();
    switch (tk.type) {
      case _TokType.string:
        // DOT concatenates adjacent quoted strings ("a" "b" → "ab"); keep
        // consuming consecutive string tokens.
        var s = tk.text;
        while (_is(_TokType.string)) {
          s += _next().text;
        }
        return s;
      case _TokType.duration:
        return tk.text; // keep as string ("900s"); timeout is stubbed in v1
      case _TokType.number:
        if (tk.text.contains('.')) {
          return double.parse(tk.text);
        }
        return int.parse(tk.text);
      case _TokType.ident:
        if (tk.text == 'true') return true;
        if (tk.text == 'false') return false;
        // Bare value (shape name, model id, etc.) — keep verbatim.
        return tk.text;
      default:
        throw DotParseError('unexpected token "${tk.text}" as attribute value');
    }
  }

  int _asInt(Object? v, int d) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? d;
    return d;
  }

  void _mergeInto(Map<String, AttrValue> dst, Map<String, AttrValue> src) =>
      dst.addAll(src);

  void _optionalSemi() {
    if (_is(_TokType.semi)) _next();
  }
}
