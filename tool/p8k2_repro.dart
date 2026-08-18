/// tin-p8k2 deterministic repro: drive the REAL notcurses rendering stack
/// (NotcursesBackend + Screen + PanelFrame + ScrollingTextRegion — the exact
/// classes the live TUI uses) inside a tmux pane through the transition that
/// spills a raster erase run over a panel border.
///
/// The shape (from the live hunt, /tmp/q4vz_live/fixed_ascii/raw_copy.log):
///
///   frame A: the chat is full of WRAPPED rows — rows that fill the plane to
///            its last column by construction (the wrap point is the budget);
///   frame B: one appended short row whose content carries a ZWJ family
///            cluster lands on a screen row that held a full row. notcurses
///            composes the cluster to 2 cells where tmux lays it out 11, so
///            the terminal cursor sits 9 cells right of nc's model when the
///            raster chains the (unaddressed) erase run for the old tail
///            directly after the content run. The run overruns the right
///            edge and its tail wraps onto the next screen row, blanking the
///            left `│` border.
///
/// Usage (inside a tmux pane of the same geometry — tool/p8k2_check.sh does
/// this and runs the checker):
///   dart run tool/p8k2_repro.dart --cols 120 --rows 40
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tina_console/src/ansi_capable.dart';
import 'package:tina_console/src/backend/backend_surface.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'package:tina_console/src/backend/terminal_backend.dart';
import 'package:tina_console/src/input_latency.dart';
import 'package:tina_console/src/panel_content.dart';
import 'package:tina_console/src/conversation_panel.dart';
import 'package:tina_console/src/rect.dart';
import 'package:tina_console/src/screen.dart';
import 'package:tina_console/src/screen_layout.dart';
import 'package:tina_console/src/stdio.dart';

/// Delegating surface that records every call to /tmp/p8k2_surface.log so
/// the repro can show exactly what the region asked the plane to do (stderr
/// would land in the pane and pollute the byte stream under test).
class _LoggingSurface implements BackendSurface {
  final BackendSurface inner;
  final IOSink log;
  _LoggingSurface(this.inner, this.log);

  void _s(String m) => log.writeln(m);

  @override
  Rect get bounds => inner.bounds;

  @override
  void putAt({
    required int relRow,
    required int relCol,
    required String text,
    required int maxCols,
    required bool moveCursor,
    int? clearCells,
  }) {
    _s('putAt(rel=$relRow,$relCol maxCols=$maxCols len=${text.length} '
        'clear=$clearCells zwj=${text.contains('‍')} '
        'esc=${text.contains('\x1b')})');
    inner.putAt(
      relRow: relRow,
      relCol: relCol,
      text: text,
      maxCols: maxCols,
      moveCursor: moveCursor,
      clearCells: clearCells,
    );
  }

  @override
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  }) {
    _s('eraseAt(rel=$relRow,$relCol n=$n)');
    inner.eraseAt(relRow: relRow, relCol: relCol, n: n, moveCursor: moveCursor);
  }

  @override
  void moveTo(int row, int col) {
    _s('moveTo($row,$col)');
    inner.moveTo(row, col);
  }

  @override
  void resize(int width, int height) {
    _s('resize($width,$height)');
    inner.resize(width, height);
  }

  @override
  void raiseToTop() => inner.raiseToTop();

  @override
  void lowerToBottom() => inner.lowerToBottom();

  @override
  bool scrollRows(int count) {
    final ok = inner.scrollRows(count);
    _s('scrollRows($count) -> $ok');
    return ok;
  }

  @override
  void destroy() => inner.destroy();
}

/// Delegating backend that wraps created surfaces in [_LoggingSurface].
/// (Everything else forwards untouched — the repro cares only about what the
/// region asks the chat plane to do.)
class _LoggingBackend implements TerminalBackend {
  final TerminalBackend inner;
  final IOSink log;
  _LoggingBackend(this.inner, this.log);

  @override
  void beginFrame() => inner.beginFrame();

  @override
  void endFrame() => inner.endFrame();

  @override
  void moveCursor(int row, int col) => inner.moveCursor(row, col);

  @override
  void parkCursor(int row, int col) => inner.parkCursor(row, col);

  @override
  void eraseCells(int row, int col, int n) => inner.eraseCells(row, col, n);

  @override
  void writeText(String text) => inner.writeText(text);

  @override
  void saveCursor() => inner.saveCursor();

  @override
  void restoreCursor() => inner.restoreCursor();

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
  void refresh() => inner.refresh();

  @override
  bool get coalescesPaints => inner.coalescesPaints;

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
  BackendSurface createSurface(Rect bounds) =>
      _LoggingSurface(inner.createSurface(bounds), log);
}

Future<void> main(List<String> argv) async {
  int cols = 120, rows = 40;
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--cols':
        cols = int.parse(argv[++i]);
      case '--rows':
        rows = int.parse(argv[++i]);
    }
  }

  InputLatency.forceEnable();
  final trace = File('/tmp/p8k2_surface.log').openWrite();
  final io = const LiveStdio();
  final backend =
      _LoggingBackend(NotcursesBackend.create(io: io), trace);
  final layout = ScreenLayout.fromSize(cols, rows, split: cols >= 100);
  final screen = Screen.withBackend(
    backend: backend,
    io: io,
    layout: layout,
    ansi: AnsiCapable.yes,
  );
  screen.enterAltScreen();
  await Future.delayed(const Duration(milliseconds: 50));

  // Primary panel chrome, exactly as tui_coordinator builds it (and exactly
  // as tool/q4vz_harness.dart does): region-owns-surface, full-height frame.
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

  screen.input.render(prompt: '> ', buffer: '', cursor: 0);
  await Future.delayed(const Duration(milliseconds: 50));

  // Frame A: wrapped rows. One long unbroken token per logical line; the wrap
  // layer breaks it at the column budget, so every visual row between the
  // first and last segment fills the plane's last column with SOLID
  // non-space content — the shape whose row-to-short-row transition damages
  // the full tail contiguously (a '047 047' style filler leaves matching
  // space cells undamaged, nc re-addresses around them, and no run chains).
  const segLen = 240; // >> any usable width at these geometries
  final filler = List.generate(
    rows + 8,
    (i) => '${i.toString().padLeft(3, '0')}${'x' * segLen}',
  ).join('\n');
  // Trailing newline: without it the reply appends onto the filler's last
  // (short) segment instead of starting a fresh row.
  // The final filler line is pure x's, an exact multiple of the chat width:
  // every segment it wraps into fills the plane's last column, so the row the
  // reply replaces (after the offset transition) is a full-width row.
  final chatWidthCells = screen.chat.bounds.width;
  final fillerText = '$filler\n${'x' * (chatWidthCells * 2)}\n';
  screen.chat.write(fillerText);
  await Future.delayed(const Duration(milliseconds: 800));
  trace.writeln('PHASE-A ${OpCounters.instance.snapshot()}');

  // Frame B: the appended reply-shaped row. Short, cluster-bearing, landing
  // on a screen row that held a full-width wrapped row after the scroll.
  // Trailing newline is deliberate now: the '\n'-terminated write into a
  // full buffer is the tin-b4n7 shape (a coalesced scroll off the native
  // fast path), and the offset transition still lands the reply on the
  // visual row that held the filler's last full-width segment.
  screen.chat.write(
    'reply: 👨‍👩‍👧‍👦 one grapheme, several code points — done\n',
  );
  await Future.delayed(const Duration(milliseconds: 800));
  trace.writeln('PHASE-B ${OpCounters.instance.snapshot()}');
  await trace.flush();

  // Hold the pane open for capture, then tear down. The sentinel goes to
  // stderr AFTER teardown — stderr lands in the pane, so anything printed
  // earlier would pollute the byte stream under test.
  await Future.delayed(const Duration(seconds: 3));
  screen.leaveAltScreen();
  await Future.delayed(const Duration(milliseconds: 300));
  stderr.writeln('P8K2-REPRO-COMPLETE');
}
