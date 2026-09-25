import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';

import '../platform/terminal_geometry.dart';
import '../tui/settings_panel.dart' show activeAccent;
import '../tui/spawn_overlay.dart' show boxLines;

/// One selectable row of the startup session picker: the session's metadata
/// plus the pre-rendered display strings (title, description, local time).
class SessionChoice {
  final SessionMeta meta;
  final String title;
  final String description;

  /// Human-formatted local timestamp, e.g. `2026-09-23 14:02`.
  final String when;

  SessionChoice({
    required this.meta,
    required this.title,
    required this.description,
    required this.when,
  });

  /// Builds the display strings from [m]: control characters are stripped
  /// (a saved title/description can neither break the layout nor inject
  /// terminal escapes), the timestamp renders as `2026-09-23 14:02` local.
  factory SessionChoice.fromMeta(SessionMeta m) {
    String clean(String v) =>
        v.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ').trim();
    return SessionChoice(
      meta: m,
      title: clean(m.title),
      description: clean(m.description ?? ''),
      when: m.updatedAt.toLocal().toString().substring(0, 16),
    );
  }
}

/// Selects one session by keyboard from a centered overlay list — the
/// pre-TUI replacement for the numbered line prompt behind `--resume`.
///
/// Typing filters the list (case-insensitive substring across title,
/// description and id), Backspace edits the filter and Tab clears it;
/// ↑/↓/PgUp/PgDn move, Enter resumes the focused session, Esc/Ctrl-C
/// cancels (null). [screen] and [readEvent] are injectable so tests drive
/// the picker without a terminal; production wraps this in
/// [pickStartupSessionId], which supplies the alt-screen and raw stdin.
Future<SessionChoice?> pickStartupSessionOverlay({
  required List<SessionChoice> choices,
  required Future<InputEvent> Function() readEvent,
  Screen? screen,
  TerminalGeometry geometry = const StdoutTerminalGeometry(),
}) async {
  if (choices.isEmpty) return null;
  final ownedScreen = screen == null;
  var s = screen;
  if (ownedScreen) {
    s = Screen(
      io: const LiveStdio(),
      layout: ScreenLayout.fromSize(
        geometry.columns >= 10 ? geometry.columns : 100,
        geometry.lines >= 10 ? geometry.lines : 40,
      ),
    );
    s.enterAltScreen();
  }
  final picker = _StartupSessionPicker(
    screen: s!,
    choices: choices,
    readEvent: readEvent,
  );
  try {
    return await picker.run();
  } finally {
    if (ownedScreen) {
      s.leaveAltScreen();
      s.dispose();
    }
  }
}

class _StartupSessionPicker {
  final Screen screen;
  final List<SessionChoice> choices;
  final Future<InputEvent> Function() readEvent;

  String query = '';
  int focus = 0;
  int scroll = 0;
  OverlayRegion? overlay;
  Rect rect = Rect.empty;

  _StartupSessionPicker({
    required this.screen,
    required this.choices,
    required this.readEvent,
  });

  static const _title = 'Resume session';
  static const _footer = '↑↓ move · enter resume · esc cancel';

  /// Entries matched by the current filter, newest first. Matching is a
  /// case-insensitive substring across title, description and session id.
  /// Ties on [SessionMeta.updatedAt] break by id (Dart's sort is not stable).
  List<SessionChoice> get matches {
    final sorted = List<SessionChoice>.of(choices)
      ..sort((a, b) {
        final byTime = b.meta.updatedAt.compareTo(a.meta.updatedAt);
        if (byTime != 0) return byTime;
        return a.meta.id.compareTo(b.meta.id);
      });
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return sorted;
    return sorted
        .where(
          (c) =>
              c.title.toLowerCase().contains(q) ||
              c.description.toLowerCase().contains(q) ||
              c.meta.id.toLowerCase().contains(q),
        )
        .toList();
  }

  /// Entry rows available between the filter line and the box furniture.
  int get _entryRowCount => (rect.height - 5).clamp(0, rect.height);

  Future<SessionChoice?> run() async {
    _layout();
    overlay = OverlayRegion(screen, rect);
    try {
      _render();
      while (true) {
        final ev = await readEvent();
        if (ev is EscapeKey ||
            (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
          return null;
        }
        if (ev is ScrollEvent) continue;
        if (ev is ArrowKey) {
          switch (ev.direction) {
            case ArrowDirection.up:
              _move(-1);
            case ArrowDirection.down:
              _move(1);
            case ArrowDirection.pageUp:
              _move(-_entryRowCount);
            case ArrowDirection.pageDown:
              _move(_entryRowCount);
            case ArrowDirection.left:
            case ArrowDirection.right:
              break;
          }
        } else if (ev is ControlKey && ev.code == ControlCode.enter) {
          final m = matches;
          if (m.isNotEmpty) return m[focus.clamp(0, m.length - 1)];
        } else if (ev is ControlKey && ev.code == ControlCode.tab) {
          if (query.isNotEmpty) {
            query = '';
            _refocus();
          }
        } else if (ev is ControlKey && ev.code == ControlCode.backspace) {
          if (query.isNotEmpty) {
            query = query.substring(0, query.length - 1);
            _refocus();
          }
        } else if (ev is CharInput) {
          query += ev.text;
          _refocus();
        }
        _render();
      }
    } finally {
      overlay!.hide();
      overlay!.dispose();
    }
  }

  void _move(int delta) {
    final m = matches;
    if (m.isEmpty) return;
    focus = (focus + delta).clamp(0, m.length - 1);
    _ensureFocusVisible();
  }

  /// Re-clamp after the filter changed: focus may point past the new match
  /// list, and the view must scroll back to the (new) focus.
  void _refocus() {
    final m = matches;
    if (focus >= m.length) focus = m.isEmpty ? 0 : m.length - 1;
    if (focus < 0) focus = 0;
    _ensureFocusVisible();
  }

  void _ensureFocusVisible() {
    final rows = _entryRowCount;
    if (rows <= 0) {
      scroll = 0;
      return;
    }
    if (focus < scroll) scroll = focus;
    if (focus >= scroll + rows) scroll = focus - rows + 1;
    if (scroll < 0) scroll = 0;
  }

  /// Centered box: a bit narrower than the terminal, capped at 100 columns;
  /// tall enough for the match list (plus filter line and box furniture),
  /// capped inside the screen with a small margin.
  void _layout() {
    final w = screen.layout.width;
    final h = screen.layout.height;
    final rows = matches.length;
    final width = (w >= 24 ? w - 8 : w).clamp(24, 100);
    final maxH = h >= 8 ? h - 4 : h;
    final height = (rows + 5).clamp(8, maxH);
    rect = Rect(
      row: (h - height) ~/ 2,
      col: (w - width) ~/ 2,
      width: width,
      height: height,
    );
    _ensureFocusVisible();
  }

  void _render() {
    _layout();
    final m = matches;
    if (focus >= m.length) focus = m.isEmpty ? 0 : m.length - 1;
    if (focus < 0) focus = 0;
    _ensureFocusVisible();
    final lines = <String>[
      query.isEmpty
          ? '\x1b[2mfilter: (type to filter — tab clears)\x1b[22m'
          : 'filter: $query',
      ..._entryLines(m),
    ];
    overlay!.update(
      bounds: rect,
      lines: boxLines(
        width: rect.width,
        height: rect.height,
        title: _title,
        body: lines,
        footer: _footer,
        paint: (s) => s,
      ),
    );
  }

  /// The visible slice of [m], focus-marked and accent-colored; a dim empty
  /// state when nothing matches.
  List<String> _entryLines(List<SessionChoice> m) {
    final accent = activeAccent(screen);
    final rows = _entryRowCount;
    if (rows <= 0) return const [];
    if (m.isEmpty) return ['\x1b[2mno sessions match — tab clears\x1b[22m'];
    final end = (scroll + rows).clamp(0, m.length);
    return [
      for (var i = scroll; i < end; i++)
        _row(m[i], focused: i == focus, accent: accent),
    ];
  }

  String _row(
    SessionChoice c, {
    required bool focused,
    required String accent,
  }) {
    String clean(String s) =>
        s.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
    final desc = clean(c.description);
    final text =
        '${focused ? '▸' : ' '} ${clean(c.title)}'
        '${desc.isEmpty ? '' : ' — $desc'}'
        '${c.when.isEmpty ? '' : '  (${clean(c.when)})'}';
    return focused ? screen.colorize(accent, text) : text;
  }
}
