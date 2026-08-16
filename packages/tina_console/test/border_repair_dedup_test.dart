import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/input_latency.dart';

import 'stdio_fake.dart';

/// Records every `moveCursor`/`writeText` call so we can count how often a
/// given border cell is re-emitted within a frame. Models the backend's
/// frame-batching contract (deferred flush) the same way
/// `screen_backend_lifecycle_test.dart`'s RecordingBackend does.
class _CountingBackend implements TerminalBackend {

  // No retained damage model in this fake; refresh is a no-op.
  @override
  void refresh() {}
  final List<({int row, int col})> moves = [];
  final List<String> writes = [];
  int _frameDepth = 0;
  bool _flushPending = false;

  @override
  void beginFrame() => _frameDepth++;

  @override
  void endFrame() {
    if (_frameDepth == 0) return;
    _frameDepth--;
    if (_frameDepth == 0 && _flushPending) {
      _flushPending = false;
    }
  }

  void _deferFlush() {
    if (_frameDepth > 0) {
      _flushPending = true;
    }
  }

  @override
  void parkCursor(int row, int col) {}

  @override
  void moveCursor(int row, int col) => moves.add((row: row, col: col));

  @override
  void eraseCells(int row, int col, int n) {}

  @override
  void writeText(String text) => writes.add(text);

  @override
  void saveCursor() {}

  @override
  void restoreCursor() {}

  @override
  void flush() => _deferFlush();

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

/// Count how many times the backend moved the cursor onto a specific cell.
int _moveCount(_CountingBackend be, int row, int col) =>
    be.moves.where((m) => m.row == row && m.col == col).length;

void main() {
  // Split layout so the info box has left/right border columns that
  // `_repairBordersForRow` re-emits on touched content rows.
  late ScreenLayout layout;
  late _CountingBackend backend;
  late Screen screen;

  setUpAll(InputLatency.forceEnable);

  setUp(() {
    InputLatency.reset();
    layout = ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true);
    backend = _CountingBackend();
    screen = Screen.withBackend(
      backend: backend,
      io: FakeStdio(),
      layout: layout,
      ansi: AnsiCapable.yes,
    );
    screen.redrawFrame(); // paints the frame once
    backend.moves.clear();
    backend.writes.clear();
  });

  test('multiple writes to one bordered row repair its border cells once', () {
    // Three writes to the same content row inside one logical frame. Before
    // the dedup, each write repaired the row's two border cells → 6 border
    // moveCursor calls. After: the row is drained once → 2 border moves.
    screen.frame(() {
      for (var i = 0; i < 3; i++) {
        screen.putAtAbsolute(
          row: 5,
          col: layout.infoLeftCol + 1 + i,
          text: 'x',
          maxCols: 1,
          moveCursor: true,
        );
      }
    });

    expect(_moveCount(backend, 5, layout.infoLeftCol), 1);
    expect(_moveCount(backend, 5, layout.infoRightCol), 1);
  });

  test('writes to different rows repair each row once', () {
    screen.frame(() {
      screen.putAtAbsolute(
        row: 5,
        col: layout.infoLeftCol + 1,
        text: 'a',
        maxCols: 1,
        moveCursor: true,
      );
      screen.putAtAbsolute(
        row: 10,
        col: layout.infoLeftCol + 1,
        text: 'b',
        maxCols: 1,
        moveCursor: true,
      );
      screen.putAtAbsolute(
        row: 15,
        col: layout.infoLeftCol + 1,
        text: 'c',
        maxCols: 1,
        moveCursor: true,
      );
    });

    // Each touched row repaired exactly once on each border column.
    for (final row in [5, 10, 15]) {
      expect(_moveCount(backend, row, layout.infoLeftCol), 1,
          reason: 'row $row left border repaired once');
      expect(_moveCount(backend, row, layout.infoRightCol), 1,
          reason: 'row $row right border repaired once');
    }
  });

  test('writes outside a frame repair synchronously (flush-on-write)', () {
    // No frame(): each leaf helper repairs immediately, so two writes to one
    // row produce two repairs (the dedup only coalesces within a frame).
    screen.putAtAbsolute(
      row: 6,
      col: layout.infoLeftCol + 1,
      text: 'a',
      maxCols: 1,
      moveCursor: true,
    );
    screen.putAtAbsolute(
      row: 6,
      col: layout.infoLeftCol + 2,
      text: 'b',
      maxCols: 1,
      moveCursor: true,
    );

    expect(_moveCount(backend, 6, layout.infoLeftCol), 2);
    expect(_moveCount(backend, 6, layout.infoRightCol), 2);
  });

  test('one frame = one presentation (flush deferred to endFrame)', () {
    // Inside a frame the backend defers flush; only endFrame resolves a
    // pending flush (one presentation per logical frame). Five writes inside
    // the frame must not produce five flushes.
    final be = _DeferCountingBackend();
    final s = Screen.withBackend(
      backend: be,
      io: FakeStdio(),
      layout: ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true),
      ansi: AnsiCapable.yes,
    );
    s.redrawFrame(); // paints the frame once → one resolution
    final before = be.flushResolutions;

    s.frame(() {
      for (var i = 0; i < 5; i++) {
        s.putAtAbsolute(
          row: 7,
          col: layout.infoLeftCol + 1 + i,
          text: 'z',
          maxCols: 1,
          moveCursor: true,
        );
      }
    });
    final delta = be.flushResolutions - before;

    // Five writes coalesced into one logical frame → exactly one flush
    // resolution at endFrame, never five.
    expect(delta, 1,
        reason: 'flushes inside a frame are deferred to endFrame, one per frame');
  });

  test('borderRepairs counter shows no repeated repair per row/frame', () {
    // The operation-count acceptance criterion: across several writes to the
    // same row in one frame, borderRepairs increments once per border cell
    // (twice for a split row), not once per write.
    final before = OpCounters.instance.borderRepairs;
    screen.frame(() {
      for (var i = 0; i < 4; i++) {
        screen.putAtAbsolute(
          row: 8,
          col: layout.infoLeftCol + 1 + i,
          text: 'q',
          maxCols: 1,
          moveCursor: true,
        );
      }
    });
    final delta = OpCounters.instance.borderRepairs - before;
    // Two border columns on the row → exactly two repairs, regardless of the
    // four writes that touched it.
    expect(delta, 2);
  });
}

/// Variant of [_CountingBackend] that also counts how many times a deferred
/// flush actually resolved (became pending) during a frame — used to assert
/// the one-frame-one-presentation property.
class _DeferCountingBackend implements TerminalBackend {
  // No retained damage model in this fake; refresh is a no-op.
  @override
  void refresh() {}
  int flushResolutions = 0;
  int _frameDepth = 0;
  bool _flushPending = false;

  @override
  void beginFrame() => _frameDepth++;

  @override
  void endFrame() {
    if (_frameDepth == 0) return;
    _frameDepth--;
    if (_frameDepth == 0 && _flushPending) {
      _flushPending = false;
      flushResolutions++;
    }
  }

  @override
  void parkCursor(int row, int col) {}
  @override
  void moveCursor(int row, int col) {}
  @override
  void eraseCells(int row, int col, int n) {}
  @override
  void writeText(String text) {}
  @override
  void saveCursor() {}
  @override
  void restoreCursor() {}
  @override
  void flush() {
    if (_frameDepth > 0) {
      _flushPending = true;
    } else {
      flushResolutions++;
    }
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
