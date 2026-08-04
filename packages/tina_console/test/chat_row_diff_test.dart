import 'dart:typed_data';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/input_latency.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

// Phase 2B acceptance tests: _emitRow now diffs each row against a retained
// painted snapshot. Unchanged rows emit nothing; changed plain rows patch only
// the suffix; styled (bar) rows and rows with unpaired surrogates fall back to
// a full rewrite. These tests pin the operation counts (skip / patch / rewrite)
// and the invalidation triggers (resize, clearChat, scroll).
//
// A counting backend records every moveCursor/writeText/eraseCells call so we
// can assert exactly how many cells a paint touched, independent of the VT's
// cell model (which is fragile for emoji/surrogates).

void main() {
  setUpAll(InputLatency.forceEnable);
  setUp(InputLatency.reset);

  test('repainting an unchanged row produces no backend cell writes', () {
    // Write a row (sets its painted snapshot), then re-emit it unchanged via
    // debugReemitRow. The skip must produce zero new writeText/eraseCells calls.
    final be = _CountingBackend();
    final screen = Screen.withBackend(
      backend: be,
      io: FakeStdio(),
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    )..redrawFrame();
    be.calls.clear();

    screen.chat.write('hello');
    expect(be.gridWriteCount, greaterThan(0), reason: 'first paint writes');
    expect(screen.chat.debugPaintedText(0), isNotNull,
        reason: 'snapshot retained after emit');

    be.calls.clear();
    screen.chat.debugReemitRow(0);
    expect(be.gridWriteCount, 0,
        reason: 're-emitting an unchanged row produces no cell writes');
    expect(be.erasedTotal, 0,
        reason: 're-emitting an unchanged row erases no cells');
  });

  test('appending one char patches only the changed suffix', () {
    // Write "hello", then append "!" — the second paint must patch just the
    // "!" cell, not rewrite all 6 cells. We detect this by counting eraseCells:
    // a full putAtAbsolute erases bounds.width cells; a patch erases only the
    // changed suffix width (1 here).
    final be = _CountingBackend();
    final screen = Screen.withBackend(
      backend: be,
      io: FakeStdio(),
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    )..redrawFrame();
    be.calls.clear();

    screen.chat.write('hello');
    final fullErase = be.erasedTotal;
    expect(fullErase, greaterThanOrEqualTo(5),
        reason: 'first write erases the whole row width');

    be.calls.clear();
    screen.chat.write('!');
    final patchErase = be.erasedTotal;

    // A patch of "!" erases ~1 cell (plus the reset/write); a full rewrite
    // would erase the full row width again. The patched erase must be strictly
    // less than the full-row erase.
    expect(patchErase, lessThan(fullErase),
        reason: 'appending one char should patch, not full-rewrite; '
            'patch erased $patchErase cells vs full $fullErase');
    expect(patchErase, lessThanOrEqualTo(2),
        reason: 'patch clears only the changed suffix (1 cell, +slack)');
  });

  test('styled (bar) row always full-rewrites, never patches', () {
    // A writeStyledLine row wraps its text in SGR, so canPatch is false. The
    // row must full-rewrite (erase full width + write), never patch.
    final be = _CountingBackend();
    final screen = Screen.withBackend(
      backend: be,
      io: FakeStdio(),
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    )..redrawFrame();
    be.calls.clear();

    screen.chat.writeStyledLine('user message', '30;47');
    final firstErase = be.erasedTotal;
    expect(firstErase, greaterThan(10),
        reason: 'styled row full-rewrites (erases the row width)');

    // Re-painting the same styled row (via resize → _redrawAll) must still
    // full-rewrite, not patch — because the SGR-wrapped text contains ESC.
    be.calls.clear();
    screen.resize(ScreenLayout.fromSize(100, 24, split: false));
    final repaintErase = be.erasedTotal;
    expect(repaintErase, greaterThan(10),
        reason: 'styled row must full-rewrite on repaint, not patch');
  });

  test('styled row with a growing tail partial-patches only the changed run',
      () {
    // The common styled-row case this feature targets: a multi-SGR row whose
    // head is unchanged but whose tail grows between paints (busy-comet sweep,
    // streaming multi-color agent prose). The prefix must be left on screen
    // untouched and only the changed tail re-emitted — a partial patch instead
    // of a full-row rewrite.
    //
    // _CountingBackend throws from createSurface, so chat renders on the
    // standard plane via the null-surface diff path (the path these diffs run
    // on). Paints are synchronous (not Notcurses, so no 8 ms coalescing).
    final be = _CountingBackend();
    final io = FakeStdio();
    final screen = Screen.withBackend(
      backend: be,
      io: io,
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    )..redrawFrame();

    // Paint 1: write the green head to the (empty) current row. This triggers
    // a _redrawAll (contentRowCount 0→1) — a full rewrite that sets the painted
    // snapshot for the row.
    screen.chat.write('\x1b[32mAB');
    final headErase = be.erasedTotal;
    expect(headErase, greaterThan(10),
        reason: 'first paint full-rewrites the row (head only)');
    expect(screen.chat.debugPaintedText(0), isNotNull,
        reason: 'snapshot retained after head paint');
    be.calls.clear();

    // Paint 2: append a blue tail to the SAME current row (no newline). The
    // row is re-emitted with previous = "\x1b[32mAB" (snapshot) and text =
    // "\x1b[32mAB\x1b[36mCD". diffStyledRuns sees the green head shared and
    // returns a span from the blue run (colOffset 2) → a partial patch.
    screen.chat.write('\x1b[36mCD');
    final tailErase = be.erasedTotal;

    // The partial patch must NOT erase the full row width: it only clears the
    // old tail (0 cells here, since the row had no tail before) and re-emits the
    // blue run at the offset column. A full rewrite would erase the whole width
    // again (headErase == content width).
    expect(tailErase, lessThan(headErase),
        reason: 'growing-tail repaint must partial-patch, not full-rewrite; '
            'erased $tailErase cells vs head $headErase');
    // The partial span is written at the offset column (border col 1 + run
    // offset 2 = col 3), not at the row origin — proving only the changed tail
    // was re-emitted, not the whole row.
    expect(be.calls.where((c) => c.startsWith('move(21,3)')), isNotEmpty,
        reason: 'partial patch writes at the tail offset column, not col 0');
    // The changed tail is the blue run "\x1b[36mCD" — renderStyledRuns emits it
    // from a clean baseline (per reset + truecolor fg + text) as a single span
    // write. The tail paint must contain exactly that span write and must NOT
    // re-emit the unchanged green head ("\x1b[32mAB" == write(7)).
    expect(be.calls.where((c) => c == 'write(23)'), hasLength(1),
        reason: 'tail paint re-emits only the changed blue span (23 bytes)');
    expect(be.calls.where((c) => c == 'write(7)'), isEmpty,
        reason: 'tail paint must not re-emit the unchanged green head');
  });

  test('resize invalidates snapshots (full rewrite after geometry change)', () {
    final be = _CountingBackend();
    final screen = Screen.withBackend(
      backend: be,
      io: FakeStdio(),
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    )..redrawFrame();
    screen.chat.write('some content');
    be.calls.clear();

    // Resize to a different width → _redrawAll nulls snapshots → every row
    // full-rewrites (gridWrites > 0), not skipped.
    screen.resize(ScreenLayout.fromSize(80, 24, split: false));
    expect(be.gridWriteCount, greaterThan(0),
        reason: 'resize forces a full repaint of all content rows');
  });

  test('clearChat then rewrite emits correctly (no stale-snapshot skip)', () {
    // The regression the invalidation audit flagged: after clearChat, the
    // snapshots must be cleared so new content renders instead of being
    // skipped as "unchanged".
    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    );
    final vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();

    screen.chat.write('first message');
    vt.feed(io.written.toString());
    io.written.clear();
    screen.clearChat();
    vt.feed(io.written.toString());
    io.written.clear();
    screen.chat.write('second message');
    vt.feed(io.written.toString());

    final bottomRow = 21; // chat content bottom-aligns to last content row (row 22 is the input row)
    expect(vt.rowText(bottomRow).contains('second message'), isTrue,
        reason: 'new content after clearChat must render, not be skipped');
    expect(vt.rowText(bottomRow).contains('first message'), isFalse,
        reason: 'cleared content must not persist');
  });

  test('surrogate pair append does not corrupt the row', () {
    // Writing an emoji whole (one segment, paired surrogate) then appending a
    // char: the paired-surrogate row must render the emoji + the new char
    // correctly. (Unpaired surrogates fall back to full rewrite; a paired
    // emoji may patch, but the result must be correct either way.)
    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    );
    final vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();

    screen.chat.write('👨');
    screen.chat.write('!');
    vt.feed(io.written.toString());

    final bottomRow = 21; // chat content bottom-aligns to last content row (row 22 is the input row)
    final row = vt.rowText(bottomRow);
    expect(row.contains('!'), isTrue, reason: 'appended char must render');
  });

  test('scrollback tail correct after sustained appends + scrolling', () {
    // Regression: 2A compaction + 2B diffing must compose. Write many lines
    // (forcing scroll + compaction) and assert the visible tail matches a
    // reference single-write run.
    final lines = <String>[];
    for (var i = 0; i < 60; i++) {
      lines.add('line-${i.toString().padLeft(3, '0')}-xxxxxxxxxxxxxxxxxx');
    }

    final refIo = FakeStdio();
    final refScreen = Screen(
      io: refIo,
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    )..redrawFrame();
    for (final line in lines) {
      refScreen.chat.writeln(line);
    }
    final refVt = VirtualTerminal(width: 100, height: 24)
      ..feed(refIo.written.toString());

    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    )..redrawFrame();
    for (final line in lines) {
      screen.chat.writeln(line);
    }
    final vt = VirtualTerminal(width: 100, height: 24)..feed(io.written.toString());

    for (var r = 0; r < 24; r++) {
      expect(vt.rowText(r), refVt.rowText(r),
          reason: 'row $r differs after compaction+scroll+diff');
    }
  });

  test('deletion clears exactly the obsolete suffix', () {
    // Chat is append-only, so "deletion" is modeled by clearChat + rewriting a
    // shorter line at the same visual row. After 2B, the shorter row must
    // clear the cells that held the longer row's suffix (the patch's
    // clearCells covers the obsolete tail).
    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24, split: false),
      ansi: AnsiCapable.yes,
    );
    final vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();

    screen.chat.write('a really long line that fills many cells');
    vt.feed(io.written.toString());
    io.written.clear();
    screen.clearChat();
    vt.feed(io.written.toString());
    io.written.clear();
    screen.chat.write('short');
    vt.feed(io.written.toString());

    final bottomRow = 21; // chat content bottom-aligns to last content row (row 22 is the input row)
    final row = vt.rowText(bottomRow);
    expect(row.contains('short'), isTrue);
    expect(row.contains('long line that fills many cells'), isFalse,
        reason: 'the obsolete suffix from the longer row must be cleared');
  });
}

/// Backend that records every cell-level call so tests can count exactly how
/// much work a paint did (full rewrite vs patch vs skip). Mirrors the
/// RecordingBackend / _CountingBackend pattern in the existing suite.
class _CountingBackend implements TerminalBackend {
  final List<String> calls = [];
  int _frameDepth = 0;
  bool _flushPending = false;

  int get gridWriteCount =>
      calls.where((c) => c.startsWith('write(')).length;
  int get erasedTotal {
    var n = 0;
    for (final c in calls) {
      if (c.startsWith('erase(')) {
        final parts = c.replaceAll(RegExp(r'[a-z()]'), '').split(',');
        if (parts.length >= 3) n += int.tryParse(parts[2]) ?? 0;
      }
    }
    return n;
  }

  @override
  void beginFrame() => _frameDepth++;
  @override
  void endFrame() {
    if (_frameDepth == 0) return;
    _frameDepth--;
    if (_frameDepth == 0 && _flushPending) {
      _flushPending = false;
      calls.add('flush');
    }
  }

  @override
  void parkCursor(int row, int col) => calls.add('park($row,$col)');
  @override
  void moveCursor(int row, int col) => calls.add('move($row,$col)');
  @override
  void eraseCells(int row, int col, int n) => calls.add('erase($row,$col,$n)');
  @override
  void writeText(String text) => calls.add('write(${text.length})');
  @override
  void saveCursor() => calls.add('save');
  @override
  void restoreCursor() => calls.add('restore');
  @override
  void flush() {
    if (_frameDepth > 0) {
      _flushPending = true;
      return;
    }
    calls.add('flush');
  }

  @override
  void enterAltScreen() {}
  @override
  void leaveAltScreen() {}
  @override
  void enableBracketedPaste() {}
  @override
  void disableBracketedPaste() {}
  @override
  bool get supportsColor => true;

  // Synchronous-style recording backend: no coalesced chat scheduling.
  @override
  bool get coalescesPaints => false;
  @override
  String colorize(String code, String text) => '\x1b[${code}m$text\x1b[0m';
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  int get terminalColumns => 100;
  @override
  BackendSurface createSurface(Rect bounds) =>
      throw UnimplementedError('unused');
  @override
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) {}
}
