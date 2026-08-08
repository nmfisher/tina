import 'dart:io';
import 'dart:math' as math;

import 'package:tina/config/user_config.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

/// The `/prompts` overlay: a modal that edits the entry agent's prompt
/// identity in a multi-line editor. Returns the written [UserConfig] on close
/// if anything changed (else null, including a bare cancel). Mirrors the
/// [runSetupOverlay] modal pattern: an [OverlayRegion] pumped by
/// [LineEditor.readKey] (the proven exclusive-capture path), with a
/// canned-[InputEvent] hook for tests.
///
/// Edits replace only the entry agent's *identity* prose; the shared
/// `<environment>` and `<project-context>` (AGENTS.md) wrapper is still applied
/// on top at resolution time. An override equal to the default identity is
/// dropped on save so the config stays clean. Writes via [writeUserConfig];
/// applies on restart.
Future<UserConfig?> runPromptsOverlay({
  required Screen screen,
  required LineEditor editor,
  required AgentPipeline pipeline,
  required Map<String, String> env,
  Directory? tinaDir,
  Future<InputEvent> Function()? readEvent,
  UserConfig? initial,
}) {
  return _PromptsForm(
    screen,
    pipeline,
    env,
    tinaDir,
    readEvent ?? editor.readKey,
    initial ?? UserConfig.empty,
  ).run();
}

enum _Step { roles, editor }

const _focusMark = '▸';
const _overriddenMark = '●';

/// One editable identity in the `/prompts` list. The catalog is gone, so the
/// only editable identity is the entry agent (`main`); this tiny type keeps the
/// list-driven form working unchanged.
class _Identity {
  final String name;
  final String description;
  final String promptIdentity;
  const _Identity(this.name, this.description, this.promptIdentity);
}

class _PromptsForm {
  _PromptsForm(
    this._screen,
    this._pipeline,
    this._env,
    this._tinaDir,
    this._readEvent,
    this._initial,
  );

  final Screen _screen;
  final AgentPipeline _pipeline;
  final Map<String, String> _env;
  final Directory? _tinaDir;
  final Future<InputEvent> Function() _readEvent;
  final UserConfig _initial;

  /// The editable identity: just the entry agent (the catalog is gone).
  List<_Identity> get _roles => [
        _Identity('main', 'the entry coding agent', _pipeline.mainIdentity),
      ];

  late final OverlayRegion _overlay;
  late final Rect _rect;
  int get _innerW => _rect.width - 4;
  int get _editorRows => _rect.height - 4;

  /// Working copy of the prompts table (role name → identity). Seeded from the
  /// loaded config; mutated by save/reset. Never holds a default-equal entry.
  final Map<String, String> _overrides = {};

  _Step _step = _Step.roles;
  int _focus = 0; // focused role index in the roles step
  String? _writeError; // set when a close-time write failed (e.g. read-only)

  // Editor-step state.
  TextBuffer? _buffer;
  _Identity? _editingRole;
  int _scrollLine = 0;

  Future<UserConfig?> run() async {
    _overrides.addAll(_initial.prompts);
    final layout = _screen.layout;
    final w = (layout.width - 4).clamp(50, 90);
    final h = (layout.height - 4).clamp(14, 28);
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
      // Esc / Ctrl-C (the app's sigint handler injects ctrlC) backs out one
      // step; at the role list it closes the overlay.
      if (ev is EscapeKey ||
          (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
        if (!_back()) {
          // Top level: close. If a prior close attempt already failed the
          // write (e.g. config on a read-only mount), discard the buffered
          // overrides and close without retrying — the error is on screen.
          if (_writeError != null) {
            _dispose();
            return null;
          }
          final r = _closeResult();
          if (r.error != null) {
            _writeError = r.error;
            _render(); // show error in the roles list, stay open
            continue;
          }
          _dispose();
          return r.config;
        }
        _render();
        continue;
      }
      _writeError = null; // any other key clears a stale write error
      _dispatch(ev);
      _render();
    }
  }

  void _dispose() {
    _overlay.hide();
    _overlay.dispose();
  }

  // -- dispatch -----------------------------------------------------------

  void _dispatch(InputEvent ev) {
    switch (_step) {
      case _Step.roles:
        _onRoles(ev);
      case _Step.editor:
        _onEditor(ev);
    }
  }

  void _onRoles(InputEvent ev) {
    if (ev is ArrowKey) {
      final page = (_rect.height - 4).clamp(1, _roles.length);
      switch (ev.direction) {
        case ArrowDirection.up:
          _focus = (_focus - 1).clamp(0, _roles.length - 1);
          return;
        case ArrowDirection.down:
          _focus = (_focus + 1).clamp(0, _roles.length - 1);
          return;
        case ArrowDirection.pageUp:
          _focus = (_focus - page).clamp(0, _roles.length - 1);
          return;
        case ArrowDirection.pageDown:
          _focus = (_focus + page).clamp(0, _roles.length - 1);
          return;
        case ArrowDirection.left:
        case ArrowDirection.right:
          return;
      }
    }
    if (ev is ControlKey && ev.code == ControlCode.enter) {
      _enterEditor(_roles[_focus]);
      return;
    }
    if (ev is CharInput && ev.text == 'r') {
      _resetRole(_roles[_focus]);
      return;
    }
  }

  void _onEditor(InputEvent ev) {
    final buf = _buffer;
    if (buf == null) return;
    if (ev is CharInput) {
      buf.insert(ev.text);
      return;
    }
    if (ev is ControlKey) {
      switch (ev.code) {
        case ControlCode.enter:
          buf.splitLine();
        case ControlCode.backspace:
          buf.backspace();
        case ControlCode.ctrlS:
          _saveEditor();
        case ControlCode.ctrlC:
        case ControlCode.tab:
        case ControlCode.ctrlL:
        case ControlCode.ctrlW:
        case ControlCode.ctrlG:
        case ControlCode.ctrlD:
          // Unused in the editor. ctrlC/Esc are handled in run()'s back path.
          break;
      }
      return;
    }
    if (ev is ArrowKey) {
      switch (ev.direction) {
        case ArrowDirection.up:
          buf.moveUp();
        case ArrowDirection.down:
          buf.moveDown();
        case ArrowDirection.left:
          buf.moveLeft();
        case ArrowDirection.right:
          buf.moveRight();
        case ArrowDirection.pageUp:
        case ArrowDirection.pageDown:
          break;
      }
      return;
    }
    if (ev is EditingKey) {
      switch (ev.action) {
        case EditingAction.home:
          buf.moveLineHome();
        case EditingAction.end:
          buf.moveLineEnd();
        case EditingAction.delete:
          buf.deleteForward();
        case EditingAction.killToEnd:
        case EditingAction.killToStart:
        case EditingAction.deleteWordBackward:
        case EditingAction.deleteWordForward:
          // Not surfaced in the editor (no TextBuffer equivalent yet).
          break;
      }
    }
  }

  // -- step transitions ---------------------------------------------------

  bool _back() {
    if (_step == _Step.editor) {
      // Discard the in-progress edit; committed overrides are already kept.
      _step = _Step.roles;
      _buffer = null;
      _editingRole = null;
      return true;
    }
    return false; // at the role list → close
  }

  void _enterEditor(_Identity role) {
    _editingRole = role;
    final effective = _overrides[role.name] ?? role.promptIdentity;
    _buffer = TextBuffer(initial: effective);
    _scrollLine = 0;
    _step = _Step.editor;
  }

  void _saveEditor() {
    final role = _editingRole;
    final buf = _buffer;
    if (role == null || buf == null) return;
    final text = buf.text;
    // An override equal to the default identity is dropped — keeps the config
    // clean and behavior identical (resolveMainPrompt falls back either way).
    if (text == role.promptIdentity) {
      _overrides.remove(role.name);
    } else {
      _overrides[role.name] = text;
    }
    _step = _Step.roles;
    _buffer = null;
    _editingRole = null;
  }

  void _resetRole(_Identity role) {
    _overrides.remove(role.name);
  }

  ({UserConfig? config, String? error}) _closeResult() {
    if (_overrides.length == _initial.prompts.length &&
        _overrides.entries.every(
            (e) => _initial.prompts[e.key] == e.value)) {
      return (config: null, error: null); // no net change
    }
    final cfg = UserConfig(
      defaultProvider: _initial.defaultProvider,
      defaultModel: _initial.defaultModel,
      providers: _initial.providers,
      limits: _initial.limits,
      prompts: Map<String, String>.from(_overrides),
    );
    try {
      writeUserConfig(cfg, env: _env, tinaDir: _tinaDir);
      return (config: cfg, error: null);
    } on ConfigWriteException catch (e) {
      return (config: null, error: e.toString());
    }
  }

  // -- render -------------------------------------------------------------

  void _render() {
    switch (_step) {
      case _Step.roles:
        _overlay.show(_box(_rolesTitle(), _rolesBody(), _rolesFooter()));
      case _Step.editor:
        _overlay.show(_box(_editorTitle(), _editorBody(), _editorFooter()));
        _parkCursor();
    }
  }

  String _rolesTitle() => 'Prompts — edit a role identity';

  List<String> _rolesBody() {
    final rows = <String>[];
    if (_writeError != null) rows.add('⚠ $_writeError');
    final roles = _roles;
    for (var i = 0; i < roles.length; i++) {
      final role = roles[i];
      final mark = _overrides.containsKey(role.name) ? _overriddenMark : ' ';
      final focused = i == _focus ? _focusMark : ' ';
      rows.add('$focused $mark ${role.name} — ${role.description}');
    }
    return rows;
  }

  String _rolesFooter() => _writeError != null
      ? 'esc discard changes (write failed) · keep editing to retry'
      : '↑↓ move · enter edit · r reset · esc done    (● = overridden)';

  String _editorTitle() {
    final role = _editingRole;
    final dirty = role != null &&
        _buffer != null &&
        _buffer!.text != (_overrides[role.name] ?? role.promptIdentity);
    return 'Editing ${role?.name ?? ""}${dirty ? " (unsaved)" : ""}';
  }

  String _editorFooter() => 'ctrl-s save · esc cancel · ↑↓←→ move · enter newline';

  /// The editor viewport: [_editorRows] rows of text, scrolled so the cursor
  /// line stays visible. The cursor line is horizontally scrolled (mirroring
  /// [InputRegion]) so the cursor column stays on-screen.
  List<String> _editorBody() {
    final buf = _buffer;
    final rows = List<String>.filled(_editorRows, '', growable: true);
    if (buf == null) return rows;
    // Keep the cursor line within the viewport.
    var first = _scrollLine;
    if (buf.line < first) first = buf.line;
    if (buf.line >= first + _editorRows) first = buf.line - _editorRows + 1;
    first = first.clamp(0, math.max(0, buf.lineCount - 1));
    _scrollLine = first;
    for (var r = 0; r < _editorRows; r++) {
      final ln = first + r;
      rows[r] = ln < buf.lineCount ? _clipLine(ln) : '~';
    }
    return rows;
  }

  /// Clip a buffer line to the inner width. The cursor line is horizontally
  /// scrolled; others show from column 0.
  String _clipLine(int ln) {
    final buf = _buffer!;
    final text = buf.lines[ln];
    final w = _innerW;
    if (ln != buf.line) {
      return text.length > w ? text.substring(0, w) : text;
    }
    var start = 0;
    if (text.length > w) {
      start = buf.col - w + 1;
      if (start < 0) start = 0;
      final cap = text.length - w;
      if (start > cap) start = cap;
    }
    return text.substring(start, math.min(text.length, start + w));
  }

  /// Park the terminal cursor at the edit cell (the overlay paints with
  /// moveCursor:false, so we position the real cursor afterward).
  void _parkCursor() {
    final buf = _buffer;
    if (buf == null) return;
    final displayLine = buf.line - _scrollLine;
    if (displayLine < 0 || displayLine >= _editorRows) return;
    final text = buf.currentLine;
    var start = 0;
    if (text.length > _innerW) {
      start = buf.col - _innerW + 1;
      if (start < 0) start = 0;
      final cap = text.length - _innerW;
      if (start > cap) start = cap;
    }
    final termRow = _rect.row + 1 + displayLine;
    final termCol = _rect.col + 2 + (buf.col - start);
    _screen.parkCursorAt(termRow, termCol);
  }

  /// Build a bordered box: titled top border, body rows, a blank line + footer,
  /// padded/truncated to [_rect.height]. Mirrors the setup overlay's box.
  List<String> _box(String title, List<String> body, String footer) {
    final w = _rect.width;
    final innerW = w - 4;
    String wrap(String s) {
      final t = s.length > innerW ? s.substring(0, innerW) : s.padRight(innerW);
      return '│ $t │';
    }

    final titleSeg = ' $title ';
    final titleFit =
        titleSeg.length > w - 2 ? titleSeg.substring(0, w - 2) : titleSeg;
    final lines = <String>[
      '┌$titleFit${'─' * (w - 2 - titleFit.length)}┐',
      ...body.map(wrap),
      wrap(''),
      wrap(footer),
    ];
    while (lines.length < _rect.height - 1) {
      lines.add(wrap(''));
    }
    lines.add('└${'─' * (w - 2)}┘');
    if (lines.length > _rect.height) {
      lines.removeRange(_rect.height, lines.length);
    }
    return lines;
  }
}
