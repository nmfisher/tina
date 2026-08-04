import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'package:tina_console/src/input_latency.dart';
import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

// Phase 3 Step 4 acceptance tests: the native-scroll fast path. When the chat
// buffer is full, a newline scrolls it. Without the fast path the coalesced
// paint does an O(H) _redrawAll; with it, _paintPending collapses N scrolls in
// a window into ONE BackendSurface.scrollRows(N) and re-emits only rows whose
// content changed (surviving rows shift up in place and skip via their adjusted
// snapshot).
//
// These tests drive the real ScrollingTextRegion scroll path through a
// NotcursesBackend backed by a RECORDING fake NotcursesPlatform, so they run in
// CI without the native library while still exercising the fast-path code. The
// surface owns a sparse char grid so a test can both assert final CELLS and
// count how much backend work a paint did. The coalesced paint runs on an 8ms
// Timer, so we drive it with fake_async's clock.

void main() {
  setUpAll(InputLatency.forceEnable);
  setUp(InputLatency.reset);

  group('native scroll fast path (coalesced notcurses)', () {
    // The fast path fires only when the buffer is full (offset 0) at BOTH
    // window start and window end. A lone writeln leaves a blank bottom row
    // (offset 1) so it falls back to _redrawAll; content that refills the blank
    // within the same window ends full and takes the fast path. These tests
    // therefore fill (flush) the buffer first, then issue window-ending-full
    // scroll input in a fresh coalesced window.
    test('a single scroll-ending-full -> one scrollRows(1), writes < H', () {
      fakeAsync((async) {
        final p = _FakeNotcursesPlatform();
        final s = _makeScreen(p, width: 120, height: 30);
        final chat = s.chat;
        _fillToFull(p, s, async);
        final surf = p.lastSurface!;
        final usable = surf.bounds.height;

        final writesBefore = surf.putAtCount;
        final scrollsBefore = surf.scrollRowsArgs.length;

        // 'A' + newline scrolls one row (offset -> 1); 'B' refills the bottom
        // blank (offset -> 0). The window ends full -> fast path.
        chat.write('A\nB');
        async.elapse(const Duration(milliseconds: 10));

        expect(surf.scrollRowsArgs.length, scrollsBefore + 1,
            reason: 'a single scroll must coalesce into exactly one scrollRows');
        expect(surf.scrollRowsArgs.last, 1,
            reason: 'a single newline scrolls exactly one row');

        final wrote = surf.putAtCount - writesBefore;
        expect(wrote, lessThan(usable),
            reason: 'fast path writes only a few rows ($wrote), not all $usable');
        expect(wrote, greaterThan(0),
            reason: 'the new bottom row must still be written');
        // The freshly-written content 'B' is the last thing on the bottom row.
        expect(surf.rowText(usable - 1), contains('B'));
      });
    });

    test('N newlines ending on content -> one scrollRows(N)', () {
      fakeAsync((async) {
        final p = _FakeNotcursesPlatform();
        final s = _makeScreen(p, width: 120, height: 30);
        final chat = s.chat;
        _fillToFull(p, s, async);
        final surf = p.lastSurface!;
        final scrollsBefore = surf.scrollRowsArgs.length;

        const n = 5;
        // n newlines (n scrolls) separated by chars, ending on a content char
        // 'Z' so the window ends full -> the whole thing is one scrollRows(n).
        final sb = StringBuffer();
        for (var i = 0; i < n; i++) {
          sb.write('x$i\n');
        }
        sb.write('Z');
        chat.write(sb.toString());
        async.elapse(const Duration(milliseconds: 10));

        expect(surf.scrollRowsArgs.length, scrollsBefore + 1,
            reason: '$n scrolls in one window coalesce to a single scrollRows');
        expect(surf.scrollRowsArgs.last, n,
            reason: 'the coalesced scroll must scroll by the full count ($n)');
      });
    });

    test('final plane content matches the ANSI reference (parity)', () {
      fakeAsync((async) {
        const height = 30;
        const width = 120;

        // Reference: ANSI backend + VirtualTerminal (ground truth).
        final ref = _runAnsiReference(width, height);

        // Native path: recording fake notcurses platform. Use the SAME
        // scroll-stream shape for both so any fast-path divergence shows up.
        final p = _FakeNotcursesPlatform();
        final s = _makeScreen(p, width: width, height: height);
        final chat = s.chat;
        s.redrawFrame();
        async.elapse(const Duration(milliseconds: 10));
        _fillToFull(p, s, async);
        _driveScrollStream(chat, newlineSeparated: false);
        async.elapse(const Duration(milliseconds: 10));
        final surf = p.lastSurface!;
        final usable = surf.bounds.height;

        // The chat plane rows 0..usable-1 show the same chat content as the
        // ANSI grid at absolute rows (chatTopRow + r).
        for (var r = 0; r < usable; r++) {
          // The chat plane's column 0 is the terminal's column 1 (column 0 is
          // the chat box's left border). Strip that border column from the
          // reference row before comparing visible content.
          final refRow =
              _stripAnsi(ref.vt.rowText(ref.chatTopRow + r)).trimRight();
          expect(surf.rowText(r), refRow.substring(1),
              reason: 'chat plane row $r final content must match ANSI ref');
        }
      });
    });
  });

  // Phase 4 follow-on: a styled row (inline SGR) whose tail changes between
  // paints must partial-patch only the changed run span on the surface, instead
  // of a full-row putAt. Drives the real surface path through the recording fake
  // notcurses platform (no native lib).
  group('styled row partial-patches changed tail on the surface', () {
    test('growing tail re-emits only the changed run at the offset column', () {
      fakeAsync((async) {
        const width = 80;
        const height = 24;
        final p = _FakeNotcursesPlatform();
        final s = _makeScreen(p, width: width, height: height);
        final chat = s.chat;
        s.redrawFrame();
        _flush(async); // let the initial frame paint

        // Paint 1: a two-run styled row — green "AB" head + blue "CD" tail.
        // First content write creates the surface and does a full putAt.
        chat.write('\x1b[32mAB\x1b[36mCD');
        _flush(async);
        final surf = p.lastSurface!;
        final fullCalls = surf.putAtCalls.length;
        // The head paint is a full putAt of the whole row at relCol 0.
        expect(surf.putAtCalls.last.relCol, 0,
            reason: 'head paint full-writes the row at the origin column');

        // Paint 2: grow the tail on the SAME current row (no newline) — append
        // another blue run. The row is re-emitted with the green head shared and
        // the blue tail changed → a partial patch from the blue run's column.
        chat.write('\x1b[36mEF');
        _flush(async);
        final patchCalls = surf.putAtCalls.sublist(fullCalls);
        // Exactly one additional putAt, and it lands at the tail offset column
        // (head "AB" == 2 cells), not the row origin — proving only the changed
        // tail span was re-emitted, not the whole row.
        expect(patchCalls, hasLength(1),
            reason: 'changed-tail repaint emits exactly one span putAt');
        expect(patchCalls.single.relCol, 2,
            reason: 'partial patch writes at the tail offset column (head width)');
        // The partial span covers only the remaining width, not the full row.
        expect(patchCalls.single.maxCols, lessThan(width),
            reason: 'partial patch maxCols is the tail span, not the full width');

        // Final cells: head "AB" + tail "CDEF" all present on the surface row.
        final row = surf.putAtCalls.last.relRow;
        final t = surf.rowText(row);
        expect(t.length, greaterThanOrEqualTo(6),
            reason: 'row holds the full head + grown tail');
        expect(t[0], 'A');
        expect(t[1], 'B');
        expect(t[2], 'C');
        expect(t[3], 'D');
        expect(t[4], 'E');
        expect(t[5], 'F');
      });
    });
  });
}

/// Fire the coalesced 8ms _paintPending deterministically.
void _flush(FakeAsync async) => async.elapse(const Duration(milliseconds: 10));

Screen _makeScreen(_FakeNotcursesPlatform p,
    {int width = 120, int height = 30}) {
  final io = FakeStdio()..columns = width;
  final backend = NotcursesBackend.forTesting(io: io, platform: p);
  return Screen.withBackend(
    backend: backend,
    io: io,
    layout: ScreenLayout.fromSize(width, height, split: false),
  );
}

// Attach the chat and fill its buffer to exactly full; return usable rows.
//
// Ending FULL matters: the native-scroll fast path only fires when the buffer
// is full (offset 0) at window end, and a buffer is full only when the LAST
// visible row carries content. A trailing newline leaves a blank bottom row
// (offset 1) and must not be how we leave the fill. So the whole fill is one
// write of a newline-separated block that ends on a content line — which also
// exercises the multi-row wrap path like real streaming prose.
int _fillToFull(_FakeNotcursesPlatform p, Screen s, FakeAsync async) {
  s.redrawFrame();
  _flush(async);
  final chat = s.chat;
  // The chat plane is created lazily on the first content draw. Write a
  // newline-separated block that ends on a content line (no trailing newline)
  // so the buffer ends exactly full (offset 0), then read the surface.
  // We don't know usable yet (no surface), so write a generous block; the
  // plane height is fixed by the layout regardless of how much we write.
  final sb = StringBuffer();
  for (var i = 0; i < 40; i++) {
    sb.write('fill-$i\n');
  }
  sb.write('fill-end');
  chat.write(sb.toString());
  _flush(async);
  final surf = p.lastSurface!;
  return surf.bounds.height; // plane sized to _usableHeight
}

void _driveScrollStream(ScrollingTextRegion chat,
    {bool newlineSeparated = true}) {
  // newlineSeparated:false emits ONE big newline-separated string that ends on
  // a content line (no trailing newline) so the coalesced window ends full and
  // exercises the native-scroll fast path. The reference run must use the same
  // shape for an apples-to-apples parity check.
  if (!newlineSeparated) {
    final sb = StringBuffer();
    for (var i = 0; i < 60; i++) {
      sb.write('line-${i.toString().padLeft(3, '0')}-xxxxxxxxxxxxxxxxxxxxxx\n');
    }
    // Drop the trailing newline so the window ends full.
    final s = sb.toString();
    chat.write(s.substring(0, s.length - 1));
    return;
  }
  for (var i = 0; i < 60; i++) {
    chat.writeln('line-${i.toString().padLeft(3, '0')}-xxxxxxxxxxxxxxxxxxxxxx');
  }
}

_AnsiRef _runAnsiReference(int width, int height) {
  final io = FakeStdio()..columns = width;
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(width, height, split: false),
  );
  screen.redrawFrame();
  final vt = VirtualTerminal(width: width, height: height);
  vt.feed(io.written.toString());
  io.written.clear();

  final chat = screen.chat;
  screen.redrawFrame();
  vt.feed(io.written.toString());
  io.written.clear();

  _driveScrollStream(chat, newlineSeparated: false);
  vt.feed(io.written.toString());

  // split:false, no menu bar -> chat content starts at row 1 (below the
  // top border row 0). Same rectangle Screen wires into the chat region.
  return _AnsiRef(vt, 1);
}

class _AnsiRef {
  final VirtualTerminal vt;
  final int chatTopRow;
  _AnsiRef(this.vt, this.chatTopRow);
}

String _stripAnsi(String s) {
  final sb = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final u = s.codeUnitAt(i);
    if (u == 0x1b && i + 1 < s.length && s.codeUnitAt(i + 1) == 0x5b) {
      i += 2;
      while (i < s.length && !(s.codeUnitAt(i) >= 0x40 && s.codeUnitAt(i) <= 0x7e)) {
        i++;
      }
      if (i < s.length) i++;
      continue;
    }
    sb.write(s[i]);
    i++;
  }
  return sb.toString();
}

/// Recording fake notcurses platform: createSurface returns recording
/// children; everything else no-ops. No z-ordering, no real planes.
class _FakeNotcursesPlatform implements NotcursesPlatform {
  _RecordingSurface? lastSurface;
  int stdGridWrites = 0;

  @override
  BackendSurface createSurface(Rect bounds) {
    final s = _RecordingSurface.forBounds(bounds);
    lastSurface = s;
    return s;
  }

  @override
  InputBackend createInputBackend() =>
      throw UnimplementedError('not used by Screen.withBackend in tests');

  @override
  void putStrYX(int row, int col, String text) => stdGridWrites++;
  @override
  void setStyles(int stylebits) {}
  @override
  void setFgRGB(int hex) {}
  @override
  void setBgRGB(int hex) {}
  @override
  void setFgDefault() {}
  @override
  void setBgDefault() {}
  @override
  bool render() => true;
  @override
  bool refresh() => true;
  @override
  void cursorEnable(int y, int x) {}
  @override
  void cursorDisable() {}
  @override
  void stop() {}
  @override
  int paletteSize() => 256;
  @override
  int planeColumns() => 120;
  @override
  int? defaultBackground() => null;
  @override
  void writeRawToTty(String s) {}
  @override
  nc.Plane? get plane => null;
  @override
  nc.NotCurses? get notc => null;
}

/// A child-plane surface backed by a sparse char grid plus backend-write
/// counters. Models what a real notcurses child plane does for chat: plane-
/// relative plain-text writes, a real grid-shifting scrollRows, erase-before-
/// write, and write counting. Z-ordering is NOT modeled — the Screen/Panel
/// layer owns that, so callers must not assert on it here.
class _RecordingSurface implements BackendSurface {
  @override
  Rect bounds;
  final int gridW;
  final Map<int, Map<int, String>> cells = {};
  int putAtCount = 0;
  int eraseAtCount = 0;
  final List<int> scrollRowsArgs = [];
  // Each putAt call recorded as (relRow, relCol, maxCols) so tests can assert a
  // partial patch landed at the span offset rather than a full-row rewrite.
  final List<({int relRow, int relCol, int maxCols})> putAtCalls = [];

  _RecordingSurface._(this.bounds, this.gridW);

  factory _RecordingSurface.forBounds(Rect b) {
    final w = b.width < 1 ? 1 : b.width;
    final h = b.height < 1 ? 0 : b.height;
    return _RecordingSurface._(Rect(row: b.row, col: b.col, width: w, height: h), w);
  }

  void _put(int relRow, int col, String ch) {
    if (relRow < 0 || relRow >= bounds.height) return;
    if (col < 0 || col >= gridW) return;
    cells.putIfAbsent(relRow, () => {})[col] = ch;
  }

  @override
  void putAt({
    required int relRow,
    required int relCol,
    required String text,
    required int maxCols,
    required bool moveCursor,
  }) {
    putAtCount++;
    putAtCalls.add((relRow: relRow, relCol: relCol, maxCols: maxCols));
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    var col = relCol;
    var visible = 0;
    var i = 0;
    while (i < text.length && visible < maxCols) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x1b && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5b) {
        // Skip a CSI sequence; it occupies no columns.
        i += 2;
        while (i < text.length &&
            !(text.codeUnitAt(i) >= 0x40 && text.codeUnitAt(i) <= 0x7e)) {
          i++;
        }
        if (i < text.length) i++;
        continue;
      }
      _put(relRow, col, String.fromCharCode(unit));
      col++;
      visible++;
      i++;
    }
  }

  @override
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  }) {
    eraseAtCount++;
    for (var k = 0; k < n; k++) {
      _put(relRow, relCol + k, ' ');
    }
  }

  @override
  bool scrollRows(int count) {
    if (count <= 0) return true;
    scrollRowsArgs.add(count);
    if (count >= bounds.height) {
      cells.clear();
      return true;
    }
    final next = <int, Map<int, String>>{};
    for (final entry in cells.entries) {
      final nr = entry.key - count;
      if (nr >= 0) next[nr] = entry.value;
    }
    cells
      ..clear()
      ..addAll(next);
    return true;
  }

  @override
  void moveTo(int row, int col) {
    bounds = Rect(row: row, col: col, width: bounds.width, height: bounds.height);
  }

  @override
  void resize(int width, int height) {
    bounds = Rect(row: bounds.row, col: bounds.col, width: width, height: height);
    cells.clear();
  }

  @override
  void raiseToTop() {}

  @override
  void lowerToBottom() {}

  @override
  void destroy() {}

  /// Plain visible text of a plane-relative row, trailing blanks trimmed.
  String rowText(int relRow) {
    if (relRow < 0 || relRow >= bounds.height) return '';
    final sb = StringBuffer();
    for (var c = 0; c < gridW; c++) {
      sb.write(cells[relRow]?[c] ?? ' ');
    }
    return sb.toString().trimRight();
  }
}
