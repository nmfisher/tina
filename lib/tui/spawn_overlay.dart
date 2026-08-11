import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

/// A model-picker overlay for the `/spawn` command: shows a flat, scrollable
/// list of `"provider/model"` references from the configured providers in the
/// registry. The user navigates with arrow keys and selects with Enter.
/// Returns the selected reference or `null` on cancel.
///
/// [configuredProviders] limits the display to providers the user set up via
/// `/settings`. [disabledModelRefs] is a set of `"provider/model"` refs the
/// user unchecked in `/settings` — models they don't want to appear in spawn.
/// When both are empty, no models are available.
///
/// [recentlyUsed] is a list of `"provider/model"` refs ordered most-recent
/// first; those that are present in the available set are surfaced at the top
/// of the list so frequently-spawned models are one or two arrows away. The
/// rest keep their registry order.
///
/// Driven by [LineEditor.readKey] like the setup overlay. [readEvent] is
/// injectable for tests.
Future<String?> runSpawnOverlay({
  required Screen screen,
  required LineEditor editor,
  required ProviderRegistry registry,
  required Set<String> configuredProviders,
  Set<String> disabledModelRefs = const {},
  List<String> recentlyUsed = const [],
  Future<InputEvent> Function()? readEvent,
}) {
  final refs = <String>[];
  for (final id in registry.providerIds) {
    if (!configuredProviders.contains(id)) continue;
    for (final m in registry.modelsFor(id)) {
      final ref = '$id/${m.id}';
      if (!disabledModelRefs.contains(ref)) refs.add(ref);
    }
  }
  final available = refs.toSet();
  final recent = recentlyUsed.where(available.contains).toList(growable: false);
  final modelRefs = recent.isEmpty
      ? refs
      : [...recent, ...refs.where((r) => !recent.contains(r))];

  return runModelPickerOverlay(
    screen: screen,
    editor: editor,
    modelRefs: modelRefs,
    title: 'Spawn agent',
    readEvent: readEvent,
  );
}

/// A model-picker overlay showing a scrollable list of [modelRefs] (each a
/// `"provider/model"` string). The caller builds the list; this function only
/// handles the UI. Returns the selected ref or `null` on cancel (Escape /
/// Ctrl-C).
///
/// Used by both `/spawn` (filtered to configured providers) and `/model`
/// (all providers in the registry).
Future<String?> runModelPickerOverlay({
  required Screen screen,
  required LineEditor editor,
  required List<String> modelRefs,
  String title = 'Select model',
  Future<InputEvent> Function()? readEvent,
  String? accent,
}) {
  final entries = modelRefs.map((r) => (display: r, value: r)).toList();
  return runListOverlay<String>(
    screen: screen,
    editor: editor,
    entries: entries,
    title: title,
    footer: '↑↓ move · enter select · esc cancel',
    readEvent: readEvent,
    accent: accent,
  );
}

/// A tool-profile picker overlay for `/spawn`/`/branch`: shows the fixed
/// [ToolProfile]s (read-only / full) and returns the chosen profile, or `null`
/// on cancel. The focused profile's tools are shown in the footer so the user
/// knows what the spawned panel will be able to do before confirming.
Future<ToolProfile?> runToolProfileOverlay({
  required Screen screen,
  required LineEditor editor,
  Future<InputEvent> Function()? readEvent,
}) {
  final profiles = ToolProfile.values;
  String label(ToolProfile p) => switch (p) {
        ToolProfile.readOnly =>
          'read-only — explore the repo (no file or shell mutation)',
        ToolProfile.full =>
          'full — read, write, edit, and run shell',
      };
  final entries = profiles
      .map((p) => (display: '${p.name} — ${label(p)}', value: p))
      .toList(growable: false);
  return runListOverlay<ToolProfile>(
    screen: screen,
    editor: editor,
    entries: entries,
    title: 'Spawn — pick a tool profile',
    // Footer reflects the focused profile's tools, so re-derive per frame.
    footer: (focus) {
      final names = toolSetFor(profiles[focus])
          .map((t) => t.schema.name)
          .toList()
        ..sort();
      return '↑↓ move · enter select · esc cancel · tools: ${names.join(", ")}';
    },
    readEvent: readEvent,
  );
}

// -- Modal focus hand-off ------------------------------------------------------
//
// While a modal is the active surface it is the single blue panel (its frame is
// colorized with the focus accent). To honor "exactly one blue panel" we blur the
// focused conversation panel for the duration of the session and refocus it on
// close. These helpers are the single seam every modal uses to do that — keeping
// the FocusManager (not the modal) the source of truth for which panel is blue.

/// For the duration of a modal session the modal is the single blue panel, so the
/// focused conversation panel must stop being blue. Release its focus at the
/// manager level (keeping the focus index consistent) and return it so the caller
/// can [modalRestoreFocus] it on close. Returns null if nothing was focused.
Focusable? modalTakeFocus(LineEditor editor) {
  final fm = editor.focusManager;
  final prev = fm?.focused;
  fm?.blurFocused();
  return prev;
}

/// Restore blue to the conversation panel that was focused before the modal opened.
void modalRestoreFocus(LineEditor editor, Focusable? prev) {
  final fm = editor.focusManager;
  if (prev != null) {
    fm?.focusPanel(prev);
  } else if (fm?.home != null) {
    fm!.home = fm.home; // re-focus home when nothing was focused
  }
}

// -- Generic list picker -------------------------------------------------------

/// A scrolled, selectable list overlay. Each [entries] item pairs a
/// [Entry.display] line with a [Entry.value] of arbitrary type [T]; returns
/// the chosen value (or null on cancel). [footer] is either a constant string
/// or a function of the focused index (to show per-item context, e.g. a
/// role's tools).
Future<T?> runListOverlay<T>({
  required Screen screen,
  required LineEditor editor,
  required List<({String display, T value})> entries,
  required String title,
  required Object? footer, // String | String Function(int focus)
  Future<InputEvent> Function()? readEvent,
  String? accent, // SGR border color; non-null ⇒ the frame is colorized cyan
}) {
  final footerFn = footer is String Function(int)
      ? footer
      : (int _) => footer as String;
  return _ListPickerForm<T>(
    screen,
    entries,
    title,
    footerFn,
    readEvent ?? editor.readKey,
    accent,
  ).run();
}

class _ListPickerForm<T> {
  _ListPickerForm(
    this._screen,
    this._entries,
    this._title,
    this._footer,
    this._readEvent,
    this._accent,
  );

  final Screen _screen;
  final List<({String display, T value})> _entries;
  final String _title;
  final String Function(int focus) _footer;
  final Future<InputEvent> Function() _readEvent;
  final String? _accent;

  late final OverlayRegion _overlay;
  late final Rect _rect;

  int _focus = 0;
  int _scrollOffset = 0;
  T? _selected;

  Future<T?> run() async {
    final layout = _screen.layout;
    final w = (layout.width - 4).clamp(40, 60);
    final h = (layout.height ~/ 2).clamp(12, layout.height - 4);
    _rect = Rect(
      row: (layout.height - h) ~/ 2,
      col: (layout.width - w) ~/ 2,
      width: w,
      height: h,
    );
    _overlay = OverlayRegion(_screen, _rect);
    _render();
    while (true) {
      final ev = await _readEvent();
      if (ev is EscapeKey ||
          (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
        _dispose();
        return null;
      }
      if (_dispatch(ev)) {
        _dispose();
        return _selected;
      }
      _render();
    }
  }

  void _dispose() {
    _overlay.hide();
    _overlay.dispose();
  }

  // -- Dispatch ---------------------------------------------------------------

  /// Returns true when the user made a selection.
  bool _dispatch(InputEvent ev) {
    if (_entries.isEmpty) return false;

    if (ev is ArrowKey) {
      final page = _rect.height - 4;
      switch (ev.direction) {
        case ArrowDirection.up:
          _focus = (_focus - 1).clamp(0, _entries.length - 1);
          _ensureFocusVisible();
        case ArrowDirection.down:
          _focus = (_focus + 1).clamp(0, _entries.length - 1);
          _ensureFocusVisible();
        case ArrowDirection.pageUp:
          _focus = (_focus - page).clamp(0, _entries.length - 1);
          _ensureFocusVisible();
        case ArrowDirection.pageDown:
          _focus = (_focus + page).clamp(0, _entries.length - 1);
          _ensureFocusVisible();
        case ArrowDirection.left:
        case ArrowDirection.right:
          break;
      }
      return false;
    }

    if (ev is ControlKey && ev.code == ControlCode.enter) {
      if (_focus >= 0 && _focus < _entries.length) {
        _selected = _entries[_focus].value;
        return true;
      }
    }

    return false;
  }

  void _ensureFocusVisible() {
    final visibleRows = (_rect.height - 4).clamp(1, _entries.length);
    if (_focus < _scrollOffset) {
      _scrollOffset = _focus;
    } else if (_focus >= _scrollOffset + visibleRows) {
      _scrollOffset = _focus - visibleRows + 1;
    }
  }

  // -- Render -----------------------------------------------------------------

  void _render() => _overlay.show(_box(_title, _body(), _footer(_focus)));

  /// Colorize [s] with the active (focus) border color — when an [accent] is set,
  /// the whole frame is tinted so the modal reads as the single blue panel.
  String _paint(String s) {
    final accent = _accent; // local copy so the null check promotes (class
    // fields don't promote below Dart 3.2).
    return accent == null ? s : _screen.colorize(accent, s);
  }

  List<String> _body() {
    if (_entries.isEmpty) return [_row(false, '(no items available)')];
    if (_focus >= _entries.length) _focus = _entries.length - 1;
    if (_focus < 0) _focus = 0;

    final visibleRows = (_rect.height - 4).clamp(1, _entries.length);
    _scrollOffset = _scrollOffset.clamp(0, _entries.length - 1);
    final end = (_scrollOffset + visibleRows).clamp(0, _entries.length);
    final slice = _entries.sublist(_scrollOffset, end);

    final hasAbove = _scrollOffset > 0;
    final hasBelow = end < _entries.length;

    final lines = <String>[];
    for (var i = 0; i < slice.length; i++) {
      final focused = (_scrollOffset + i) == _focus;
      lines.add(_row(focused, slice[i].display));
    }

    // Overflow indicators
    if (hasBelow && lines.isNotEmpty) {
      final nBelow = _entries.length - _scrollOffset - slice.length;
      lines[lines.length - 1] = _row(false, '↓ $nBelow more');
    }
    if (hasAbove && lines.isNotEmpty) {
      final nAbove = _scrollOffset;
      lines[0] = _row(false, '↑ $nAbove more');
    }

    return lines;
  }

  String _row(bool focused, String text) =>
      '${focused ? _focusMark : ' '} $text';

  // -- Box renderer -----------------------------------------------------------

  static const _focusMark = '▸';

  List<String> _box(String title, List<String> body, String footer) =>
      _boxLines(
        width: _rect.width,
        height: _rect.height,
        title: title,
        body: body,
        footer: footer,
        paint: _paint,
      );
}

/// One bordered content row inside a [_boxLines] frame.
String _wrapLine(int innerW, String s, String Function(String) paint) {
  final t = s.length > innerW ? s.substring(0, innerW) : s.padRight(innerW);
  return '${paint('│')} $t ${paint('│')}';
}

/// The bordered box shared by the list picker and the question form: title
/// bar, [body] rows, a blank separator, the footer, padded to [height], with
/// any overflow truncated.
List<String> _boxLines({
  required int width,
  required int height,
  required String title,
  required List<String> body,
  required String footer,
  required String Function(String) paint,
}) {
  final w = width;
  final innerW = w - 4;
  final titleSeg = ' $title ';
  final titleFit =
      titleSeg.length > w - 2 ? titleSeg.substring(0, w - 2) : titleSeg;
  final lines = <String>[
    '${paint('┌')}${paint(titleFit)}${paint('─' * (w - 2 - titleFit.length))}${paint('┐')}',
    ...body.map((s) => _wrapLine(innerW, s, paint)),
    _wrapLine(innerW, '', paint),
    _wrapLine(innerW, footer, paint),
  ];
  while (lines.length < height - 1) {
    lines.add(_wrapLine(innerW, '', paint));
  }
  lines.add('${paint('└')}${paint('─' * (w - 2))}${paint('┘')}');
  if (lines.length > height) {
    lines.removeRange(height, lines.length);
  }
  return lines;
}

/// A multi-question selection form: one or more questions, each with a list of
/// options. ↑/↓ move the option focus within the focused question; ←/→ move
/// between questions (each keeps its own option focus); Enter confirms ALL
/// questions at once; Esc/Ctrl-C cancels. Returns the chosen option label per
/// question (index-aligned), or null on cancel. The opencode/Claude-Code-style
/// primitive backing the agent's `ask_user` tool.
Future<List<String>?> runQuestionOverlay({
  required Screen screen,
  required LineEditor editor,
  required List<({String text, List<String> options})> questions,
  Future<InputEvent> Function()? readEvent,
}) =>
    _QuestionForm(screen, questions, readEvent ?? editor.readKey).run();

class _QuestionForm {
  _QuestionForm(this._screen, this._questions, this._readEvent);

  final Screen _screen;
  final List<({String text, List<String> options})> _questions;
  final Future<InputEvent> Function() _readEvent;

  late final OverlayRegion _overlay;
  late final Rect _rect;

  int _questionFocus = 0;
  final List<int> _optionFocus = [];
  final List<int> _selections = [];
  int _scrollOffset = 0;

  Future<List<String>?> run() async {
    if (_questions.isEmpty) return const [];
    for (var i = 0; i < _questions.length; i++) {
      _optionFocus.add(0);
      _selections.add(0);
    }
    final layout = _screen.layout;
    final w = (layout.width - 4).clamp(40, 60);
    final h = (layout.height * 2 ~/ 3).clamp(12, layout.height - 4);
    _rect = Rect(
      row: (layout.height - h) ~/ 2,
      col: (layout.width - w) ~/ 2,
      width: w,
      height: h,
    );
    _overlay = OverlayRegion(_screen, _rect);
    _render();
    while (true) {
      final ev = await _readEvent();
      if (ev is EscapeKey ||
          (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
        _dispose();
        return null;
      }
      if (_dispatch(ev)) {
        _dispose();
        return [
          for (var q = 0; q < _questions.length; q++)
            _questions[q].options[_selections[q]],
        ];
      }
      _render();
    }
  }

  void _dispose() {
    _overlay.hide();
    _overlay.dispose();
  }

  /// Returns true when the user confirmed.
  bool _dispatch(InputEvent ev) {
    if (ev is ArrowKey) {
      final options = _questions[_questionFocus].options;
      switch (ev.direction) {
        case ArrowDirection.up:
          if (options.isNotEmpty) {
            _optionFocus[_questionFocus] =
                (_optionFocus[_questionFocus] - 1).clamp(0, options.length - 1);
          }
        case ArrowDirection.down:
          if (options.isNotEmpty) {
            _optionFocus[_questionFocus] =
                (_optionFocus[_questionFocus] + 1).clamp(0, options.length - 1);
          }
        case ArrowDirection.left:
          if (_questionFocus > 0) _questionFocus--;
        case ArrowDirection.right:
          if (_questionFocus < _questions.length - 1) _questionFocus++;
        case ArrowDirection.pageUp:
        case ArrowDirection.pageDown:
          break; // no paging in the question form
      }
      _ensureFocusedVisible();
      return false;
    }
    if (ev is ControlKey && ev.code == ControlCode.enter) {
      for (var q = 0; q < _questions.length; q++) {
        _selections[q] = _optionFocus[q];
      }
      return true;
    }
    return false;
  }

  /// The body row index of the focused option.
  int _focusedRow() {
    var row = 0;
    for (var q = 0; q < _questionFocus; q++) {
      row += 1 + _questions[q].options.length + 1; // question + options + blank
    }
    return row + 1 + _optionFocus[_questionFocus];
  }

  void _ensureFocusedVisible() {
    final visible = (_rect.height - 4).clamp(1, 1 << 30);
    if (_focusedRow() < _scrollOffset) {
      _scrollOffset = _focusedRow();
    } else if (_focusedRow() >= _scrollOffset + visible) {
      _scrollOffset = _focusedRow() - visible + 1;
    }
  }

  // -- Render -----------------------------------------------------------------

  void _render() => _overlay.show(_boxLines(
        width: _rect.width,
        height: _rect.height,
        title: 'Questions',
        body: _body(),
        footer: '↑↓ option · ←→ question · enter confirm · esc cancel',
        paint: _paint,
      ));

  String _paint(String s) => _screen.colorize('cyan', s);

  List<String> _body() {
    final all = <String>[];
    for (var q = 0; q < _questions.length; q++) {
      final qFocus = q == _questionFocus;
      all.add(qFocus ? '▸ ${_questions[q].text}' : '  ${_questions[q].text}');
      final options = _questions[q].options;
      for (var o = 0; o < options.length; o++) {
        final oFocus = qFocus && o == _optionFocus[q];
        all.add(oFocus ? '    ▸ ${options[o]}' : '      ${options[o]}');
      }
      if (q < _questions.length - 1) all.add('');
    }

    final visible = (_rect.height - 4).clamp(1, all.length);
    _scrollOffset = _scrollOffset.clamp(0, all.length - 1);
    final end = (_scrollOffset + visible).clamp(0, all.length);
    final slice = all.sublist(_scrollOffset, end);
    if (_scrollOffset > 0 && slice.isNotEmpty) {
      slice[0] = '↑ $_scrollOffset more';
    }
    if (end < all.length && slice.isNotEmpty) {
      slice[slice.length - 1] = '↓ ${all.length - end} more';
    }
    return slice;
  }
}
