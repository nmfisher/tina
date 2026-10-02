import '../tina_console.dart';
import 'input_display.dart';

/// The opencode-style model picker: a type-to-filter search field pinned at
/// the top, and the models grouped under colored provider headers below.
///
/// [modelRefs] are `"provider/model"` strings in registry order; the groups
/// follow the first appearance of each provider. [recentRefs] (most recent
/// first) get a dedicated "Recent" group above the provider groups — the
/// one-or-two-arrows-away quick access for frequently used models. The
/// Recent group shows only while the query is empty.
///
/// Typing filters case-insensitively against the full `provider/model` ref
/// and the provider display name; empty groups hide. Focus moves over model
/// rows only (headers are skipped), so arrow order matches the visible order.
/// Returns the selected ref, or null on Escape / Ctrl-C.
///
/// Driven by [LineEditor.readKey] like the other overlays; [readEvent] is
/// injectable for tests.
Future<String?> runModelSearchOverlay({
  required Screen screen,
  required LineEditor editor,
  required List<String> modelRefs,
  required Map<String, String> providerNames,
  String title = 'Select model',
  List<String> recentRefs = const [],
  Future<InputEvent> Function()? readEvent,
  String? accent,
}) =>
    ModelSearchPicker(
      screen: screen,
      modelRefs: modelRefs,
      providerNames: providerNames,
      title: title,
      recentRefs: recentRefs,
      readEvent: readEvent ?? editor.captureKeyReader(),
      accent: accent,
    ).run();

/// One provider group in the unfiltered list.
class _Group {
  final String providerId;
  final List<String> refs;
  _Group(this.providerId, this.refs);
}

/// The original searchable model picker, shared by conversation and settings
/// surfaces. [repaint] reflows the open picker after a terminal resize.
class ModelSearchPicker {
  ModelSearchPicker({
    required Screen screen,
    required List<String> modelRefs,
    required Map<String, String> providerNames,
    required Future<InputEvent> Function() readEvent,
    String title = 'Select model',
    List<String> recentRefs = const [],
    Map<String, String> modelNames = const {},
    String? accent,
  })  : _screen = screen,
        _modelRefs = modelRefs,
        _providerNames = providerNames,
        _title = title,
        _recentRefs = recentRefs,
        _modelNames = modelNames,
        _readEvent = readEvent,
        _accent = accent;

  final Map<String, String> _modelNames;
  bool _open = false;
  void repaint() {
    if (_open) _render();
  }

  final Screen _screen;
  final List<String> _modelRefs;
  final Map<String, String> _providerNames;
  final String _title;
  final List<String> _recentRefs;
  final Future<InputEvent> Function() _readEvent;
  final String? _accent;

  late final OverlayRegion _overlay;
  late Rect _rect;

  String _query = '';
  int _focus = 0; // index into the filtered model refs
  int _scrollOffset = 0; // first visible display row, including headings
  String? _selected;

  /// The filtered refs in display order (Recent group first when the query is
  /// empty, provider groups otherwise).
  late List<String> _filtered;

  /// Provider groups over the unfiltered refs — the source of header colors
  /// and the provider order, kept stable while filtering hides groups.
  late final List<_Group> _allGroups;

  /// recentRefs ∩ available, MRU order. Only rendered while the query is
  /// empty; its refs also stay under their provider groups.
  late final List<String> _recent;

  static const _focusMark = '▸';

  Future<String?> run() async {
    final available = _modelRefs.toSet();
    _recent =
        _recentRefs.where(available.contains).toSet().toList(growable: false);
    final groups = <String, List<String>>{};
    for (final ref in _modelRefs) {
      final slash = ref.indexOf('/');
      final pid = slash <= 0 ? ref : ref.substring(0, slash);
      groups.putIfAbsent(pid, () => []).add(ref);
    }
    _allGroups = [for (final e in groups.entries) _Group(e.key, e.value)];
    _filtered = _computeFiltered();

    _overlay = OverlayRegion(_screen, Rect.empty);
    final cursor = _screen.claimCursor();
    _open = true;
    try {
      _render();
      while (true) {
        final ev = await _readEvent();
        if (ev is EscapeKey ||
            (ev is ControlKey && ev.code == ControlCode.ctrlC)) return null;
        if (_dispatch(ev)) return _selected;
        _render();
      }
    } finally {
      _open = false;
      _overlay.hide();
      _overlay.dispose();
      cursor.release();
    }
  }

  List<String> _computeFiltered() {
    if (_query.isEmpty) {
      return [..._recent, ..._modelRefs];
    }
    final q = _query.toLowerCase();
    bool matches(String ref, String providerId) =>
        ref.toLowerCase().contains(q) ||
        (_modelNames[ref] ?? '').toLowerCase().contains(q) ||
        (_providerNames[providerId] ?? providerId).toLowerCase().contains(q);
    return [
      for (final g in _allGroups)
        for (final ref in g.refs)
          if (matches(ref, g.providerId)) ref,
    ];
  }

  String _providerOf(String ref) {
    final slash = ref.indexOf('/');
    return slash <= 0 ? ref : ref.substring(0, slash);
  }

  String _displayName(String providerId) {
    final name = _providerNames[providerId] ?? providerId;
    return name.isEmpty
        ? providerId
        : name[0].toUpperCase() + name.substring(1);
  }

  // -- Dispatch ---------------------------------------------------------------

  /// Returns true when the user made a selection.
  bool _dispatch(InputEvent ev) {
    // The search field swallows text first: typing refines the filter.
    if (ev is CharInput) {
      _query += inputDisplayText(ev.text);
      _refilter();
      return false;
    }
    if (ev is PasteInput) {
      _query += inputDisplayText(ev.text).trim();
      _refilter();
      return false;
    }
    if (ev is ControlKey) {
      switch (ev.code) {
        case ControlCode.backspace:
          if (_query.isNotEmpty) {
            _query = String.fromCharCodes(_query.runes.toList()..removeLast());
            _refilter();
          }
          return false;
        case ControlCode.enter:
          if (_filtered.isEmpty) return false;
          _selected = _filtered[_focus];
          return true;
        default:
          break;
      }
    }
    if (ev is EditingKey && ev.action == EditingAction.killToStart) {
      _query = '';
      _refilter();
      return false;
    }
    if (ev is ArrowKey) {
      if (_filtered.isEmpty) return false;
      final page = _visibleRows;
      switch (ev.direction) {
        case ArrowDirection.up:
          _focus = (_focus - 1).clamp(0, _filtered.length - 1);
        case ArrowDirection.down:
          _focus = (_focus + 1).clamp(0, _filtered.length - 1);
        case ArrowDirection.pageUp:
          _focus = (_focus - page).clamp(0, _filtered.length - 1);
        case ArrowDirection.pageDown:
          _focus = (_focus + page).clamp(0, _filtered.length - 1);
        case ArrowDirection.left:
        case ArrowDirection.right:
          break;
      }
      return false;
    }
    return false;
  }

  void _refilter() {
    _filtered = _computeFiltered();
    _focus = 0;
    _scrollOffset = 0;
  }

  int get _visibleRows => (_rect.height - 6).clamp(1, 1 << 30);

  // -- Render -----------------------------------------------------------------

  void _render() {
    final area = dialogArea(_screen.layout);
    final w = (area.width - 8).clamp(0, 76);
    final width = area.width < 56 ? area.width : w;
    final height = (area.height * 2 ~/ 3)
        .clamp(area.height < 12 ? area.height : 12, area.height);
    _rect = Rect(
      row: area.row + (area.height - height) ~/ 2,
      col: area.col + (area.width - width) ~/ 2,
      width: width,
      height: height,
    );
    if (height < 7) {
      final lines = [
        _title,
        '/ $_query▌',
        if (_filtered.isEmpty)
          '(no models match)'
        else
          '▸ ${_filtered[_focus]}',
        '↑↓ · Enter select · Esc cancel',
      ];
      _overlay.update(
          bounds: _rect,
          lines: lines
              .take(height)
              .map((line) => clipToVisibleColumns(line, width))
              .toList());
      return;
    }
    _overlay.update(
        bounds: _rect,
        lines: dialogBoxLines(
          width: _rect.width,
          height: _rect.height,
          title: _query.isEmpty
              ? _title
              : '$_title — ${_filtered.length} match'
                  '${_filtered.length == 1 ? '' : 'es'}',
          body: _body(),
          footer: _rect.width < 56
              ? '↑↓ move · Enter select · Esc cancel'
              : 'type to filter · ↑↓ move · enter select · esc cancel',
          paint: _paint,
        ));
  }

  /// Colorize [s] with the active (focus) border color — when an [accent] is
  /// set, the whole frame is tinted so the modal reads as the single blue
  /// panel.
  String _paint(String s) {
    final accent = _accent; // local copy so the null check promotes
    return accent == null ? s : _screen.colorize(accent, s);
  }

  String _dim(String s) => _screen.colorize(_screen.theme.chat.dim, s);

  /// The cursor + focused-model highlight color: the accent when one is set,
  /// cyan otherwise.
  String get _accentColor => _accent ?? 'cyan';

  /// Header color: one shared color (the modal's accent) for every provider
  /// header — the grouping already carries the structure, a per-provider
  /// palette just adds noise.
  String get _headerColor => _accentColor;

  /// The search field: a dim `/` prompt, the query, and an accent block
  /// cursor — one visual unit with the rule beneath it, reading as a text
  /// input rather than a labeled line above an unrelated divider. An empty
  /// query shows a dim placeholder instead of a dangling cursor.
  List<String> _searchField(int innerW) {
    final budget = (innerW - 8).clamp(1, 1 << 30);
    final q = String.fromCharCodes(
        _query.runes.toList().reversed.take(budget).toList().reversed);
    final prompt = '  ${_dim('/')} ';
    final text = _query.isEmpty
        ? '${_dim('filter models…')}${_screen.colorize(_accentColor, '▌')}'
        : '$q${_screen.colorize(_accentColor, '▌')}';
    return ['$prompt$text', _dim('  ${'─' * (innerW - 4).clamp(0, 1 << 30)}')];
  }

  List<String> _body() {
    final innerW = _rect.width - 4;
    // Body rows boxLines puts inside the frame (it adds the blank + footer
    // rows itself): height minus top border, footer row, blank row, bottom
    // border.
    final contentRows = _rect.height - 4;

    if (_filtered.isEmpty) {
      return [..._searchField(innerW), '  ${_dim('(no models match)')}'];
    }
    if (_focus >= _filtered.length) _focus = _filtered.length - 1;
    if (_focus < 0) _focus = 0;

    final lines = _searchField(innerW);
    lines.addAll(_fitRows(contentRows - lines.length));
    return lines;
  }

  /// Keep the selected model visible, counting provider headings against the
  /// same row budget. The footer and border always stay inside the frame.
  List<String> _fitRows(int cap) {
    if (cap <= 0) return [];
    final rows = <String>[];
    final recentLen = _query.isEmpty ? _recent.length : 0;
    var focusedRow = 0;
    String? previous;
    for (var i = 0; i < _filtered.length; i++) {
      final ref = _filtered[i];
      final key = i < recentLen ? '__recent__' : _providerOf(ref);
      if (key != previous && cap > 1) {
        rows.add(key == '__recent__'
            ? '  ${_screen.colorize(_headerColor, 'Recent')}'
            : '  ${_screen.colorize(_headerColor, _displayName(key))}'
                '${_dim(' (${_groupCount(key)})')}');
        previous = key;
      }
      final slash = ref.indexOf('/');
      final modelId = slash <= 0 ? ref : ref.substring(slash + 1);
      if (i == _focus) focusedRow = rows.length;
      rows.add(i == _focus
          ? '  $_focusMark ${_screen.colorize(_accentColor, modelId)}'
          : '    $modelId');
    }
    if (focusedRow < _scrollOffset) _scrollOffset = focusedRow;
    if (focusedRow >= _scrollOffset + cap) _scrollOffset = focusedRow - cap + 1;
    _scrollOffset =
        _scrollOffset.clamp(0, (rows.length - cap).clamp(0, rows.length));
    return rows.skip(_scrollOffset).take(cap).toList();
  }

  /// The count shown next to a header: the full group size when unfiltered,
  /// the matched count when filtering.
  int _groupCount(String providerId) {
    if (_query.isEmpty) {
      return _allGroups
          .firstWhere((g) => g.providerId == providerId)
          .refs
          .length;
    }
    return _filtered.where((r) => _providerOf(r) == providerId).length;
  }
}
