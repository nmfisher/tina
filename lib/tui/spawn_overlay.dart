import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import 'package:tina/tui/model_search_overlay.dart';

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
///
/// [activeModelRef] (the `"provider/model"` the active conversation runs
/// under, e.g. `"stub/stub-1"`) seeds pickers for configured providers whose
/// registry catalog contributes ZERO entries — the usual case for user-defined
/// providers, which have no compiled model list. When the active model belongs
/// to such a provider, that model is offered as a single entry so the picker
/// is not empty (and Enter isn't swallowed on `(no items available)`); it's
/// deduplicated against the catalog entries and honors [disabledModelRefs].
Future<String?> runSpawnOverlay({
  required Screen screen,
  required LineEditor editor,
  required ProviderRegistry registry,
  required Set<String> configuredProviders,
  Set<String> disabledModelRefs = const {},
  List<String> recentlyUsed = const [],
  String? activeModelRef,
  Future<InputEvent> Function()? readEvent,
}) {
  final refs = <String>[];
  final names = <String, String>{};
  final zeroCatalog = <String>[]; // configured ids that contributed no refs
  for (final id in registry.providerIds) {
    names[id] = registry.descriptor(id)?.name ?? id;
    if (!configuredProviders.contains(id)) continue;
    var contributed = false;
    for (final m in registry.modelsFor(id)) {
      final ref = '$id/${m.id}';
      if (!disabledModelRefs.contains(ref)) {
        refs.add(ref);
        contributed = true;
      }
    }
    if (!contributed) zeroCatalog.add(id);
  }
  // Seed the active model into the first zero-catalog configured provider it
  // belongs to (custom providers, primarily). Skipped when the active model
  // is unchecked in /settings — the user explicitly excluded it from spawn.
  if (activeModelRef != null) {
    final slash = activeModelRef.indexOf('/');
    final providerId = slash < 0 ? activeModelRef : activeModelRef.substring(0, slash);
    final modelId = slash < 0 ? '' : activeModelRef.substring(slash + 1);
    if (providerId.isNotEmpty && modelId.isNotEmpty) {
      final idx = zeroCatalog.indexOf(providerId);
      if (idx >= 0 && !disabledModelRefs.contains(activeModelRef)) {
        zeroCatalog.removeAt(idx);
        refs.add(activeModelRef);
      }
    }
  }
  final available = refs.toSet();
  final recent = recentlyUsed.where(available.contains).toList(growable: false);

  return runModelPickerOverlay(
    screen: screen,
    editor: editor,
    modelRefs: refs,
    title: 'Spawn agent',
    readEvent: readEvent,
    providerNames: names,
    recentRefs: recent,
  );
}

/// A model-picker overlay: [modelRefs] (each a `"provider/model"` string)
/// rendered as a searchable, provider-grouped list (see
/// [runModelSearchOverlay]). The caller builds the list; this function only
/// handles the UI. Returns the selected ref or `null` on cancel (Escape /
/// Ctrl-C).
///
/// Used by both `/spawn` (filtered to configured providers) and `/model`
/// (all providers in the registry). [providerNames] maps provider id →
/// display name for the group headers; [recentRefs] surface at the top.
Future<String?> runModelPickerOverlay({
  required Screen screen,
  required LineEditor editor,
  required List<String> modelRefs,
  String title = 'Select model',
  Future<InputEvent> Function()? readEvent,
  String? accent,
  Map<String, String> providerNames = const {},
  List<String> recentRefs = const [],
}) {
  return runModelSearchOverlay(
    screen: screen,
    editor: editor,
    modelRefs: modelRefs,
    providerNames: providerNames,
    title: title,
    recentRefs: recentRefs,
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
  String? body, // optional explanatory text rendered inside the box, above the entries
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
    body,
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
    this._bodyText,
  );

  final Screen _screen;
  final List<({String display, T value})> _entries;
  final String _title;
  final String Function(int focus) _footer;
  final Future<InputEvent> Function() _readEvent;
  final String? _accent;
  final String? _bodyText;

  late final OverlayRegion _overlay;
  late final Rect _rect;

  /// Wrapped lines of [_bodyText], or empty when no body was supplied. The
  /// body lives in its own scrollable pane above a fixed entry strip so the
  /// selectable entries stay visible even when the explanation is taller than
  /// the panel.
  List<String> _bodyLines = const <String>[];
  int _bodyScroll = 0;

  int _focus = 0;
  int _scrollOffset = 0;
  T? _selected;

  /// Rows available for the body pane: the box interior minus the entry strip.
  int get _bodyRowsAvail {
    final contentRows = _rect.height - 4;
    if (_entries.length < contentRows) {
      return (contentRows - _entries.length).clamp(1, contentRows);
    }
    return 1;
  }

  int get _bodyScrollMax {
    if (_bodyLines.isEmpty) return 0;
    final m = _bodyLines.length - _bodyRowsAvail;
    return m < 0 ? 0 : m;
  }

  Future<T?> run() async {
    final layout = _screen.layout;
    final w = (layout.width - 4).clamp(40, 60);
    final innerW = w - 4;
    final bodyText = _bodyText;
    _bodyLines = bodyText == null
        ? const <String>[]
        : _wrapParagraph(bodyText, innerW);
    // Grow the popup to fit a body block (capped to the screen) so the
    // explanation renders inside the panel instead of being squeezed out.
    final h = bodyText == null
        ? (layout.height ~/ 2).clamp(12, layout.height - 4)
        : (_bodyLines.length + _entries.length + 4).clamp(12, layout.height - 4);
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
          // At the top entry with a body above: scroll the body instead of
          // trying to move focus further up.
          if (_bodyLines.isNotEmpty &&
              _focus == 0 &&
              _bodyScroll > 0) {
            _bodyScroll -= 1;
          } else {
            _focus = (_focus - 1).clamp(0, _entries.length - 1);
            _ensureFocusVisible();
          }
        case ArrowDirection.down:
          // At the bottom entry with body below: scroll the body.
          if (_bodyLines.isNotEmpty &&
              _focus == _entries.length - 1 &&
              _bodyScroll < _bodyScrollMax) {
            _bodyScroll += 1;
          } else {
            _focus = (_focus + 1).clamp(0, _entries.length - 1);
            _ensureFocusVisible();
          }
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
    // No explanatory body: original entry-only layout, byte-for-byte.
    if (_bodyLines.isEmpty) {
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

    // Explanatory body + entries: the body scrolls in its own pane above a
    // (mostly) fixed entry strip, so selectable entries stay visible even when
    // the explanation is taller than the panel. Indicators replace a body row
    // so the box stays height-aligned.
    final contentRows = _rect.height - 4;
    final nBody = _bodyLines.length;

    if (_entries.isEmpty) {
      final rows = _bodyRowsAvail.clamp(1, contentRows);
      _bodyScroll = _bodyScroll.clamp(0, _bodyScrollMax);
      final showAbove = _bodyScroll > 0;
      var end = (_bodyScroll + rows).clamp(0, nBody);
      final showBelow = end < nBody;
      final indicators = (showAbove ? 1 : 0) + (showBelow ? 1 : 0);
      final textRows = (rows - indicators).clamp(0, nBody);
      end = (_bodyScroll + textRows).clamp(0, nBody);
      final lines = <String>[];
      if (showAbove) lines.add(_row(false, '↑ $_bodyScroll more'));
      for (var i = _bodyScroll; i < end; i++) {
        lines.add(_bodyLines[i]);
      }
      if (showBelow) lines.add(_row(false, '↓ ${nBody - end} more'));
      return lines;
    }

    final nEntries = _entries.length;
    final entryRows =
        nEntries < contentRows ? nEntries : (contentRows - 1).clamp(1, contentRows);
    final bodyRows = _bodyRowsAvail.clamp(1, contentRows - entryRows);
    _bodyScroll = _bodyScroll.clamp(0, _bodyScrollMax);
    final showAbove = _bodyScroll > 0;
    var end = (_bodyScroll + bodyRows).clamp(0, nBody);
    final showBelow = end < nBody;
    final indicators = (showAbove ? 1 : 0) + (showBelow ? 1 : 0);
    final textRows = (bodyRows - indicators).clamp(0, nBody);
    end = (_bodyScroll + textRows).clamp(0, nBody);

    final lines = <String>[];
    if (showAbove) lines.add(_row(false, '↑ $_bodyScroll more'));
    for (var i = _bodyScroll; i < end; i++) {
      lines.add(_bodyLines[i]);
    }
    if (showBelow) lines.add(_row(false, '↓ ${nBody - end} more'));

    // Entry strip — always visible at the bottom of the panel.
    for (var i = 0; i < nEntries; i++) {
      lines.add(_row(i == _focus, _entries[i].display));
    }
    return lines;
  }

  String _row(bool focused, String text) =>
      '${focused ? _focusMark : ' '} $text';

  // -- Box renderer -----------------------------------------------------------

  static const _focusMark = '▸';

  List<String> _box(String title, List<String> body, String footer) =>
      boxLines(
        width: _rect.width,
        height: _rect.height,
        title: title,
        body: body,
        footer: footer,
        paint: _paint,
      );
}

/// One bordered content row inside a [boxLines] frame. Rows may embed ANSI
/// SGR sequences (colorized text); those carry no width, so padding is
/// computed on the VISIBLE length — a raw `String.length` pad would leave
/// colored rows short of (or past) the right border.
String _wrapLine(int innerW, String s, String Function(String) paint) {
  final vis = _visibleLength(s);
  String t;
  if (vis > innerW) {
    // Hard clip on visible cells, then re-establish the default style — the
    // clip may land mid-run, leaving an SGR sequence open.
    t = '${_clipVisible(s, innerW)}\x1b[0m';
  } else {
    t = '$s${' ' * (innerW - vis)}';
  }
  return '${paint('│')} $t ${paint('│')}';
}

final _ansiEscape = RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]');

/// The printable width of [s]: its length with ANSI escapes removed.
int _visibleLength(String s) => s.replaceAll(_ansiEscape, '').length;

/// Keep the first [n] visible cells of [s], dropping escapes that start
/// beyond the clip point.
String _clipVisible(String s, int n) {
  final buf = StringBuffer();
  var vis = 0;
  for (var i = 0; i < s.length;) {
    final m = _ansiEscape.matchAsPrefix(s, i);
    if (m != null) {
      buf.write(m[0]);
      i = m.end;
      continue;
    }
    if (vis >= n) break;
    buf.write(s[i]);
    vis++;
    i++;
  }
  return buf.toString();
}

/// Greedy word-wrap [text] to [innerW] columns, preserving blank
/// `\n`-separated paragraphs. Used to flow an optional picker `body` inside
/// [boxLines].
List<String> _wrapParagraph(String text, int innerW) {
  final out = <String>[];
  for (final para in text.split('\n')) {
    if (para.isEmpty) {
      out.add('');
      continue;
    }
    var cur = '';
    for (final w in para.split(RegExp(r'\s+'))) {
      if (w.isEmpty) continue;
      if (cur.isEmpty) {
        cur = w;
      } else if (cur.length + 1 + w.length <= innerW) {
        cur += ' $w';
      } else {
        out.add(cur);
        cur = w;
      }
    }
    if (cur.isNotEmpty) out.add(cur);
  }
  return out;
}

/// The bordered box shared by the list picker and the question form: title
/// bar, [body] rows, a blank separator, the footer, padded to [height], with
/// any overflow truncated.
List<String> boxLines({
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
/// options. It renders INLINE AT THE INPUT FIELD — the options occupy the rows
/// directly above the input line (the completion-picker placement: the input's
/// column and width, growing upward into the chat area), and the input row
/// itself carries the focused question — NOT a centered panel popover.
///
/// Keys: ↑/↓ move the option focus within the focused question; ←/→ move
/// between questions (each keeps its own option focus); Enter SELECTS the
/// focused option for the focused question — committing it and advancing to
/// the next question — and only submits the form when pressed on the LAST
/// question (owner bug report: Enter on the first option used to submit the
/// whole thing, which read as if the form had never been navigated). A
/// question reached by ←/→ without its own Enter falls back to its focused
/// option. Esc/Ctrl-C cancels. Returns the chosen option label per question
/// (index-aligned), or null on cancel. The opencode/Claude-Code-style
/// primitive backing the agent's `ask_user` tool.
Future<List<String>?> runQuestionOverlay({
  required Screen screen,
  required LineEditor editor,
  required List<({String text, List<String> options})> questions,
  Future<InputEvent> Function()? readEvent,
}) =>
    _QuestionForm(screen, editor, questions, readEvent ?? editor.readKey).run();

class _QuestionForm {
  _QuestionForm(this._screen, this._editor, this._questions, this._readEvent);

  final Screen _screen;
  final LineEditor _editor;
  final List<({String text, List<String> options})> _questions;
  final Future<InputEvent> Function() _readEvent;

  late final OverlayRegion _overlay = OverlayRegion(_screen, Rect.empty);

  int _questionFocus = 0;
  final List<int> _optionFocus = [];

  /// Per question, the option index confirmed by an Enter on that question,
  /// or null when the user only navigated past it (its focused option is the
  /// implicit answer at submit time).
  final List<int?> _committed = [];
  int _scrollOffset = 0;

  Future<List<String>?> run() async {
    if (_questions.isEmpty) return const [];
    for (var i = 0; i < _questions.length; i++) {
      _optionFocus.add(0);
      _committed.add(null);
    }
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
            _questions[q].options[_committed[q] ?? _optionFocus[q]],
        ];
      }
      _render();
    }
  }

  void _dispose() {
    _overlay.hide();
    _overlay.dispose();
    // The form painted the input row with the focused question; hand the row
    // back. A parked readLine repaints itself; an idle input row is erased so
    // no question text lingers after the form is gone.
    if (_editor.isEditing) {
      _editor.refresh();
    } else {
      _screen.input.erase();
    }
  }

  /// Returns true when the LAST question was Enter-confirmed — the only event
  /// that submits the form.
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
      // Enter SELECTS the focused option for the focused question — it does
      // NOT submit the form unless this is the last question.
      _committed[_questionFocus] = _optionFocus[_questionFocus];
      if (_questionFocus < _questions.length - 1) {
        _questionFocus++;
        _ensureFocusedVisible();
        return false;
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
    final visible = (_availableHeight() - 1).clamp(1, 1 << 30); // footer row
    if (_focusedRow() < _scrollOffset) {
      _scrollOffset = _focusedRow();
    } else if (_focusedRow() >= _scrollOffset + visible) {
      _scrollOffset = _focusedRow() - visible + 1;
    }
  }

  /// Rows the form may occupy: from just above the input row (skipping the
  /// separator) up to the chat ceiling — the completion-picker geometry.
  int _availableHeight() {
    final inputRow = _screen.input.bounds.row;
    final bottomRow = inputRow - 1;
    return bottomRow - _screen.layout.chat.row + 1;
  }

  // -- Render -----------------------------------------------------------------

  void _render() {
    final body = _body();
    final footer = _dim('  ↑↓ option · ←→ question · enter select · esc cancel');
    final maxH = _availableHeight();
    final wanted = body.length + 1; // + footer
    final h = wanted > maxH ? maxH : wanted;
    if (h <= 0) return; // degenerate geometry: nothing to paint
    _scrollOffset = _scrollOffset.clamp(0, body.length - 1);
    final end = (_scrollOffset + h - 1).clamp(0, body.length); // footer takes 1
    final slice = body.sublist(_scrollOffset, end);
    if (_scrollOffset > 0 && slice.isNotEmpty) {
      slice[0] = _dim('  ↑ ${_scrollOffset} more');
    }
    if (end < body.length && slice.isNotEmpty) {
      slice[slice.length - 1] = _dim('  ↓ ${body.length - end} more');
    }
    final inputBounds = _screen.input.bounds;
    _overlay.reposition(Rect(
      row: (inputBounds.row - 1) - h + 1,
      col: inputBounds.col,
      width: inputBounds.width,
      height: h,
    ));
    _overlay.show([...slice, footer]);
    _renderInputRow();
  }

  /// The input row carries the focused question while the form runs — the
  /// questions live IN the input field, not in a detached popover.
  void _renderInputRow() {
    final q = _questions[_questionFocus];
    _screen.input.render(
      prompt: '❯ ',
      buffer: q.text,
      cursor: q.text.length,
    );
  }

  String _dim(String s) => _screen.ansi.useColor
      ? _screen.colorize(_screen.theme.completion.dim, s)
      : s;

  String _hi(String s) => _screen.ansi.useColor
      ? _screen.colorize(_screen.theme.completion.selected, s)
      : s;

  List<String> _body() {
    final all = <String>[];
    for (var q = 0; q < _questions.length; q++) {
      final qFocus = q == _questionFocus;
      all.add(qFocus ? _hi('❯ ${_questions[q].text}') : _dim('  ${_questions[q].text}'));
      final options = _questions[q].options;
      for (var o = 0; o < options.length; o++) {
        // No arrow indicator on options (owner follow-up 2026-08-24): ▸ read
        // as a collapsed/expander chevron. Focus is the selected COLOR alone —
        // the completion picker's convention; a committed answer keeps its
        // filled dot, which marks choice, not expandability.
        final oFocus = qFocus && o == _optionFocus[q];
        if (oFocus) {
          all.add(_hi('    ${options[o]}'));
        } else if (_committed[q] == o) {
          all.add(_dim('  ● ${options[o]}')); // Enter-confirmed on this pass
        } else {
          all.add(_dim('    ${options[o]}'));
        }
      }
      if (q < _questions.length - 1) all.add(_dim(''));
    }
    return all;
  }
}
