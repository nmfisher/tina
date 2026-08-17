/// tin-q4vz hunt harness: drive the REAL notcurses rendering stack
/// (NotcursesBackend + Screen + PanelFrame + ScrollingTextRegion, the exact
/// classes the live TUI uses) inside a tmux pane, feed it the paste corpus,
/// and log every backend-level operation so the border-loss defect can be
/// localized to a specific write/scroll/render.
///
/// Usage (inside a tmux pane of the same geometry):
///   dart run tool/q4vz_harness.dart --body /tmp/paste5k.txt \
///       --cols 120 --rows 40 --log /tmp/q4vz_harness.log [--busy]
///
/// The process stays alive after the run so the outer script can capture the
/// pane; kill it when done.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tina_console/src/ansi_capable.dart';
import 'package:tina_console/src/backend/backend_surface.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'package:tina_console/src/backend/terminal_backend.dart';
import 'package:tina_console/src/panel_content.dart';
import 'package:tina_console/src/conversation_panel.dart';
import 'package:tina_console/src/rect.dart';
import 'package:tina_console/src/screen.dart';
import 'package:tina_console/src/screen_layout.dart';
import 'package:tina_console/src/stdio.dart';

IOSink? _log;
int _seq = 0;

void _say(String s) {
  _log?.writeln('${_seq.toString().padLeft(5)} $s');
  _seq++;
}

/// Delegating backend that records every standard-plane mutation and every
/// render/refresh/flush, and wraps created surfaces in [_LoggingSurface].
class _LoggingBackend implements TerminalBackend {
  final NotcursesBackend inner;
  _LoggingBackend(this.inner);

  @override
  void beginFrame() {
    _say('beginFrame');
    inner.beginFrame();
  }

  @override
  void endFrame() {
    _say('endFrame');
    inner.endFrame();
  }

  @override
  void moveCursor(int row, int col) {
    _cursor = (row, col);
    inner.moveCursor(row, col);
  }

  (int, int) _cursor = (0, 0);

  @override
  void parkCursor(int row, int col) {
    _say('parkCursor($row,$col)');
    inner.parkCursor(row, col);
  }

  @override
  void eraseCells(int row, int col, int n) {
    _cursor = (row, col);
    if (col == 0 || col < 4) {
      _say('eraseCells(row=$row,col=$col,n=$n)  <-- near/ON border col');
    }
    inner.eraseCells(row, col, n);
  }

  @override
  void writeText(String text) {
    final (r, c) = _cursor;
    if (c == 0) {
      _say('writeText@($r,0) len=${text.length} '
          '${text.substring(0, text.length > 24 ? 24 : text.length)}');
    }
    inner.writeText(text);
  }

  @override
  void saveCursor() => inner.saveCursor();

  @override
  void restoreCursor() {
    inner.restoreCursor();
    // restoreCursor rewinds to the pre-save position; track it loosely —
    // exact tracking isn't needed, we only flag col-0 writes.
  }

  @override
  void flush() => inner.flush();

  @override
  void enterAltScreen() => inner.enterAltScreen();

  @override
  void leaveAltScreen() => inner.leaveAltScreen();

  @override
  void enableBracketedPaste() => inner.enableBracketedPaste();

  @override
  void disableBracketedPaste() => inner.disableBracketedPaste();

  @override
  bool get supportsColor => inner.supportsColor;

  @override
  String colorize(String code, String text) => inner.colorize(code, text);

  @override
  Stream<List<int>> get stdin => inner.stdin;

  @override
  int get terminalColumns => inner.terminalColumns;

  @override
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) {
    inner.renderImageAbsolute(
      row: row,
      col: col,
      rgba: rgba,
      width: width,
      height: height,
      maxCols: maxCols,
      targetSurface: targetSurface,
    );
  }

  @override
  BackendSurface createSurface(Rect bounds) {
    final s = inner.createSurface(bounds);
    _say('createSurface($bounds) -> wrapping');
    return _LoggingSurface(s, bounds);
  }

  @override
  void refresh() {
    _say('refresh()');
    inner.refresh();
  }

  @override
  bool get coalescesPaints => inner.coalescesPaints;
}

/// Delegating surface that records putAt/eraseAt/scroll/move/resize with
/// enough detail to see column-0 clobbers and native-scroll counts.
class _LoggingSurface implements BackendSurface {
  final BackendSurface inner;
  final Rect created;
  _LoggingSurface(this.inner, this.created);

  @override
  Rect get bounds => inner.bounds;

  @override
  void putAt({
    required int relRow,
    required int relCol,
    required String text,
    required int maxCols,
    required bool moveCursor,
  }) {
    final head = text.length > 32 ? text.substring(0, 32) : text;
    _say('surface.putAt(rel=$relRow,$relCol maxCols=$maxCols '
        'len=${text.length} esc=${text.contains('\x1b')}) "$head"');
    inner.putAt(
      relRow: relRow,
      relCol: relCol,
      text: text,
      maxCols: maxCols,
      moveCursor: moveCursor,
    );
  }

  @override
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  }) {
    _say('surface.eraseAt(rel=$relRow,$relCol n=$n)');
    inner.eraseAt(relRow: relRow, relCol: relCol, n: n, moveCursor: moveCursor);
  }

  @override
  void moveTo(int row, int col) {
    _say('surface.moveTo($row,$col)');
    inner.moveTo(row, col);
  }

  @override
  void resize(int width, int height) {
    _say('surface.resize($width,$height)');
    inner.resize(width, height);
  }

  @override
  void raiseToTop() => inner.raiseToTop();

  @override
  void lowerToBottom() => inner.lowerToBottom();

  @override
  bool scrollRows(int count) {
    _say('surface.scrollRows($count)');
    return inner.scrollRows(count);
  }

  @override
  void destroy() => inner.destroy();
}

Future<void> main(List<String> argv) async {
  String bodyPath = '/tmp/paste5k.txt';
  String logPath = '/tmp/q4vz_harness.log';
  int cols = 120, rows = 40;
  bool busy = false;
  bool stream = false;
  bool script = false;
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--body':
        bodyPath = argv[++i];
      case '--log':
        logPath = argv[++i];
      case '--cols':
        cols = int.parse(argv[++i]);
      case '--rows':
        rows = int.parse(argv[++i]);
      case '--busy':
        busy = true;
      case '--stream':
        stream = true;
      case '--script':
        script = true;
    }
  }
  final body = File(bodyPath).readAsStringSync();
  _log = File(logPath).openWrite();
  _say('harness start cols=$cols rows=$rows body=${body.length} chars '
      'busy=$busy stream=$stream');

  final io = const LiveStdio();
  final backend = _LoggingBackend(NotcursesBackend.create(io: io));
  final layout = ScreenLayout.fromSize(cols, rows, split: cols >= 100);
  final screen = Screen.withBackend(
    backend: backend,
    io: io,
    layout: layout,
    ansi: AnsiCapable.yes,
  );
  screen.enterAltScreen();
  await Future.delayed(const Duration(milliseconds: 50));

  // Primary panel chrome, exactly as tui_coordinator builds it: no
  // ownsCanvas (region-owns-surface), outer rect from the layout's chat box.
  final chatWidth = layout.chat.width + 2;
  final frame = PanelFrame(
    screen: screen,
    label: 'main (stub-1)',
    conversationId: 'c1',
  )..setReservesInput(true);
  frame.setOuter(Rect(row: 0, col: 0, width: chatWidth, height: rows));
  ChatRegionPanelContent(screen.chat)
      .fit(frame.interior, reserveInputRow: frame.reservesInput);
  await Future.delayed(const Duration(milliseconds: 50));

  // The editor's parked cursor, as the input row would leave it.
  screen.input.render(prompt: '> ', buffer: '', cursor: 0);
  await Future.delayed(const Duration(milliseconds: 50));
  _say('=== chrome up; submitting paste ===');

  if (script) {
    // The live-session shape: startup banner, a filling agent turn, the paste
    // echo on a FULL buffer, then more agent turns streaming while busy.
    screen.chat.write('tina — /help · /exit · /clear\n');
    screen.chat.dim('session: 20260817-stub\n');
    await Future.delayed(const Duration(milliseconds: 30));

    Future<void> agentTurn(List<String> chunks) async {
      frame.setBusy(true);
      screen.chat.beginStyle(screen.theme.chat.agentText);
      for (final c in chunks) {
        screen.chat.appendStyled(c);
        frame.advanceBusyTick();
        await Future.delayed(const Duration(milliseconds: 12));
      }
      screen.chat.endStyle();
      frame.setBusy(false);
      await Future.delayed(const Duration(milliseconds: 30));
    }

    // Turn 1 — fills the buffer and starts native scrolling.
    await agentTurn(List.generate(
      30,
      (i) =>
          'EventBus.publish queues a publish made from inside a subscriber '
          'callback, and dispatches it only after the current dispatch '
          'finishes. Reentrant publishes therefore never interleave.\n'
          'Source: packages/core/lib/src/event_bus.dart\n',
    ));

    // The paste echo — user bar, whole body, one write on a full buffer.
    screen.input.render(
        prompt: '> ', buffer: '[Pasted text : 6000 chars]', cursor: 24);
    await Future.delayed(const Duration(milliseconds: 20));
    screen.chat.writeStyledLine(body, screen.theme.chat.userBar);
    await Future.delayed(const Duration(milliseconds: 30));
    screen.input.render(prompt: '> ', buffer: '', cursor: 0);
    await Future.delayed(const Duration(milliseconds: 30));

    // Turn 2 — streams while the paste rows scroll away.
    await agentTurn(List.generate(
      12,
      (i) => 'queued $i arrives and renders after the paste body\n',
    ));

    // A final user line, as the next submitted message.
    screen.chat.writeStyledLine(
        'queued one\nqueued two\nqueued three\n',
        screen.theme.chat.userBar);
    await Future.delayed(const Duration(milliseconds: 200));
    await Future.delayed(const Duration(milliseconds: 800));
    _say('=== run complete; idling for pane capture ===');
    await Future.delayed(const Duration(seconds: 55));
    screen.leaveAltScreen();
    _log?.close();
    return;
  }

  if (stream) {
    // Stream the body in chunks with real-time gaps, toggling busy mid-stream
    // like an agent turn interleaved with the paste echo.
    const chunk = 400;
    frame.setBusy(true);
    for (var i = 0; i < body.length; i += chunk) {
      final slice = body.substring(
          i, i + chunk > body.length ? body.length : i + chunk);
      screen.chat.appendStyled(slice);
      frame.advanceBusyTick();
      await Future.delayed(const Duration(milliseconds: 12));
    }
    frame.setBusy(false);
  } else {
    // The paste echo: one user-bar styled line carrying the whole body.
    if (busy) frame.setBusy(true);
    screen.chat.writeStyledLine(body, screen.theme.chat.userBar);
    await Future.delayed(const Duration(milliseconds: 30));
    if (busy) {
      frame.advanceBusyTick();
      await Future.delayed(const Duration(milliseconds: 30));
      frame.setBusy(false);
    }
  }

  // Let the trailing coalescing presentation land, then let the outer script
  // capture the pane.
  await Future.delayed(const Duration(milliseconds: 800));
  _say('=== run complete; idling for pane capture ===');
  await Future.delayed(const Duration(seconds: 55));
  screen.leaveAltScreen();
  _log?.close();
}
