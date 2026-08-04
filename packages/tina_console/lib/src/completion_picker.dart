import 'package:fuzzy_ranker/fuzzy_ranker.dart';
import 'rect.dart';
import 'region.dart';
import 'screen.dart';

/// Popup completion menu opened by typing `@` at a word boundary.
///
/// Owns an [OverlayRegion] positioned just above the input region (so it
/// grows upward into the chat area instead of through the bottom border).
/// Query lookups are async; concurrent typing produces newer generations
/// that supersede in-flight ones.
class CompletionPicker {
  final Screen _screen;
  late OverlayRegion _overlay;

  /// Source of completion suggestions.
  CompletionProvider? provider;

  /// Character code that opens the picker (default `@` = 0x40).
  final int trigger;

  /// Maximum number of items the panel shows / navigates at once. Set high for
  /// short static lists (e.g. the command palette) so every item is reachable,
  /// since navigation wraps over `min(results, maxRows)` items.
  final int maxRows;

  /// Reported to the LineEditor's `onError` if provider throws.
  void Function(Object error, StackTrace stack)? onError;

  /// Decides whether typing [trigger] should open the picker, given the
  /// pre-insert buffer/cursor. Defaults to [_atWordBoundary] (the `@` rule:
  /// start of line or after whitespace). A `/` picker overrides it to open only
  /// at the start of an empty line.
  final bool Function(String buffer, int cursor) shouldOpen;

  /// When true (the `@` default), the accepted text is prefixed with the trigger
  /// char (results store the bare value, e.g. a file path). When false, results
  /// already include their own sigil (e.g. `/help`) so the trigger isn't added.
  final bool prependTriggerOnAccept;

  /// Appended to the accepted text — e.g. a trailing space so a completed
  /// command is ready to receive arguments.
  final String acceptSuffix;

  bool _active = false;
  bool _loading = false;
  int _anchor = -1;
  List<String> _results = const [];
  int _selected = 0;
  int _queryGen = 0;

  CompletionPicker(
    this._screen, {
    this.provider,
    this.onError,
    this.trigger = 0x40,
    this.maxRows = 8,
    this.prependTriggerOnAccept = true,
    this.acceptSuffix = '',
    bool Function(String, int)? shouldOpen,
  }) : shouldOpen = shouldOpen ?? _atWordBoundary {
    _overlay = OverlayRegion(_screen, Rect.empty);
  }

  /// The `/`-command picker: opens only at the start of an empty line, accepts
  /// the result verbatim (results already carry the slash) plus a trailing
  /// space so a completed command is ready to receive arguments. Used by the
  /// [LineEditor] command palette and its tests.
  factory CompletionPicker.commandPicker(
    Screen screen, {
    CompletionProvider? provider,
    void Function(Object error, StackTrace stack)? onError,
  }) =>
      CompletionPicker(
        screen,
        trigger: 0x2f,
        shouldOpen: (buffer, cursor) => buffer.isEmpty && cursor == 0,
        prependTriggerOnAccept: false,
        acceptSuffix: ' ',
        maxRows: 32,
        provider: provider,
        onError: onError,
      );

  bool get isActive => _active;
  int get anchor => _anchor;

  bool shouldTrigger(int charCode, String buffer, int cursor) {
    if (charCode != trigger) return false;
    if (_active) return false;
    if (provider == null) return false;
    return shouldOpen(buffer, cursor);
  }

  void open(int anchor) {
    _active = true;
    _anchor = anchor;
    _selected = 0;
    _results = const [];
    _loading = true;
    _render();
  }

  void closeState() {
    if (!_active) return;
    _active = false;
    _loading = false;
    _anchor = -1;
    _results = const [];
    _selected = 0;
    _queryGen++;
    _overlay.hide();
  }

  void reset() => closeState();

  String queryFromBuffer(String buffer, int cursor) {
    if (!_active || _anchor < 0) return '';
    if (cursor <= _anchor + 1) return '';
    return buffer.substring(_anchor + 1, cursor);
  }

  Future<bool> refresh(String buffer, int cursor) async {
    final prov = provider;
    if (!_active || prov == null) return false;
    final gen = ++_queryGen;
    final query = queryFromBuffer(buffer, cursor);
    List<String> results;
    try {
      results = await prov.complete(query);
    } catch (e, st) {
      onError?.call(e, st);
      results = const [];
    }
    if (gen != _queryGen || !_active) return false;
    _results = results;
    _loading = false;
    if (_selected >= _results.length) _selected = 0;
    _render();
    return true;
  }

  void navigateUp() {
    if (!_active || _results.isEmpty) return;
    final n = _visibleCount();
    _selected = (_selected - 1 + n) % n;
    _render();
  }

  void navigateDown() {
    if (!_active || _results.isEmpty) return;
    final n = _visibleCount();
    _selected = (_selected + 1) % n;
    _render();
  }

  /// Returns the replacement spec, or null if nothing to accept.
  ({int start, int end, String text})? accept(String buffer, int cursor) {
    if (!_active || _results.isEmpty) return null;
    final pick = _results[_selected];
    final core = prependTriggerOnAccept
        ? '${String.fromCharCode(trigger)}$pick'
        : pick;
    return (start: _anchor, end: cursor, text: '$core$acceptSuffix');
  }

  void dispose() {
    _overlay.dispose();
  }

  // -- Rendering ----------------------------------------------------------

  void _render() {
    if (!_active) return;
    final layout = _screen.layout;
    // Picker bottom = the row just above the input, skipping the
    // separator border in split mode. Picker top = bottom - h + 1, capped
    // so it never reaches above the top border / row 0.
    final inputRow = _screen.input.bounds.row;
    // Picker sits just above the input row, always inside the chat box.
    final bottomRow = inputRow - 1;
    final ceiling = layout.chat.row;
    final wanted = _visibleCount().clamp(1, maxRows);
    final maxH = bottomRow - ceiling + 1;
    final h = wanted > maxH ? maxH : wanted;
    if (h <= 0) {
      _overlay.hide();
      return;
    }
    final topRow = bottomRow - h + 1;
    _overlay.reposition(
      Rect(
        row: topRow,
        col: _screen.input.bounds.col,
        width: _screen.input.bounds.width,
        height: h,
      ),
    );
    _overlay.show(_lines(h));
  }

  int _visibleCount() {
    if (_loading && _results.isEmpty) return 1;
    if (_results.isEmpty) return 1;
    return _results.length > maxRows ? maxRows : _results.length;
  }

  List<String> _lines(int height) {
    final useColor = _screen.ansi.useColor;
    String dim(String s) =>
        useColor ? _screen.colorize(_screen.theme.completion.dim, s) : s;
    String hi(String s) =>
        useColor ? _screen.colorize(_screen.theme.completion.selected, s) : s;
    if (_loading && _results.isEmpty) return [dim('  (loading…)')];
    if (_results.isEmpty) return [dim('  (no matches)')];

    final visible = _results.length > maxRows
        ? _results.sublist(0, maxRows)
        : _results;
    final maxLen = _screen.input.bounds.width - 2;
    final lines = <String>[];
    for (var i = 0; i < visible.length && i < height; i++) {
      final entry = visible[i];
      final shown = (maxLen > 0 && entry.length > maxLen)
          ? '…${entry.substring(entry.length - maxLen + 1)}'
          : entry;
      lines.add(i == _selected ? hi('  $shown') : dim('  $shown'));
    }
    return lines;
  }

  static bool _atWordBoundary(String buffer, int cursor) {
    if (cursor == 0) return true;
    final prev = buffer.codeUnitAt(cursor - 1);
    return prev == 0x20 || prev == 0x09;
  }
}
