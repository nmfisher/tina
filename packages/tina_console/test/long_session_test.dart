import 'dart:typed_data';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// Long-session invariants for [ScrollingTextRegion]:
///
///  - a detached (hidden/parked) panel's replay buffer is bounded, with the
///    dropped head reported on reattach;
///  - a row-count-neutral rewrite (the streaming hot path: a block whose body
///    re-renders to the same number of rows) re-emits only the rewritten rows
///    instead of repainting the whole window.
void main() {
  test('detached replay buffer stays bounded and reports dropped lines', () {
    final io = FakeStdio()..columns = 40;
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(40, 12, split: false, drawInfoFrame: false),
      ansi: AnsiCapable.yes,
    );
    final r = ScrollingTextRegion(
      screen,
      bounds: const Rect(row: 0, col: 0, width: 30, height: 6),
    )..attach();
    r.write('before detach\n');
    r.detach();

    // ~1 MiB of one-line records: far past the cap, all while hidden.
    for (var i = 0; i < 6000; i++) {
      r.write('line ${i.toString().padLeft(5, '0')} '
          '${'x' * 150}\n');
    }
    final bufferedAfterFlood = r.debugDetachedBufferLength;
    expect(
      bufferedAfterFlood,
      lessThanOrEqualTo(ScrollingTextRegion.debugDetachedBufferCap),
      reason: 'the detached buffer must stay capped under a sustained flood',
    );

    r.attach();
    // The omission notice plus the kept tail live in scrollback; the window
    // only shows the newest rows, so read the region's retained snapshot.
    final retained = r.snapshotLines().join('\n');
    expect(retained, contains('earlier line'),
        reason: 'clipped replay is announced, never silent');
    expect(retained, contains('line 05999'),
        reason: 'the newest records survive the trim');
    expect(retained, isNot(contains('line 00000')),
        reason: 'the oldest records were dropped by the cap');
    // attach() consumes the dropped counter into the notice, so assert the
    // announced count from the notice text itself.
    final match = RegExp(r'(\d+) earlier lines? omitted').firstMatch(retained);
    expect(match, isNotNull);
    expect(int.parse(match!.group(1)!), greaterThan(0));
    expect(r.debugDetachedDroppedLines, 0,
        reason: 'the counter resets after it is announced on attach');
  });

  for (final prefix in ['', 'prefix\n']) {
    for (final terminated in [false, true]) {
      test(
          'detached replay bounds a long line: '
          'prefix=${prefix.isNotEmpty}, terminated=$terminated', () {
        final screen = Screen(
            io: FakeStdio(),
            layout: ScreenLayout.fromSize(80, 24, split: false));
        addTearDown(screen.dispose);
        final region = ScrollingTextRegion(screen)..attach();
        region.detach();
        region.write('$prefix${'x' * (1024 * 1024)}'
            '${terminated ? '\nnewest\n' : ''}');
        expect(region.debugDetachedBufferLength,
            lessThanOrEqualTo(ScrollingTextRegion.debugDetachedBufferCap));
        if (!terminated) {
          region.write('continued');
          expect(region.debugDetachedBufferLength, 0);
          region.write(' remainder\nnewest\n');
        }
        region.attach();
        final retained = region.snapshotLines().join('\n');
        expect(retained, contains('newest'));
        expect(retained, contains('earlier line'));
        expect(retained, isNot(contains('continued')));
        expect(retained, isNot(contains('remainder')));
        expect(region.debugDetachedDroppedLines, 0);
      });
    }
  }

  test('clearing a discarded detached line allows a fresh line to replay', () {
    final screen = Screen(
        io: FakeStdio(), layout: ScreenLayout.fromSize(80, 24, split: false));
    addTearDown(screen.dispose);
    final region = ScrollingTextRegion(screen)..attach();
    region.detach();
    region.write('x' * (1024 * 1024));
    region.resetAfterClear();
    region.write('fresh\n');
    region.attach();
    expect(region.snapshotLines().join('\n'), contains('fresh'));
    expect(region.debugDetachedDroppedLines, 0);
  });

  test('a flood while detached replays the kept tail correctly', () {
    final io = FakeStdio()..columns = 40;
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(40, 12, split: false, drawInfoFrame: false),
      ansi: AnsiCapable.yes,
    );
    final r = ScrollingTextRegion(
      screen,
      bounds: const Rect(row: 0, col: 0, width: 30, height: 6),
    )..attach();
    r.detach();
    r.write('a\nb\nc\n');
    for (var i = 0; i < 4000; i++) {
      r.write('record $i\n');
    }
    r.attach();
    expect(r.contentRows, greaterThan(3));
    // The tail is intact: the last written record is the newest row.
    expect(
      r.snapshotLines().last.trim(),
      contains('record 3999'),
    );
  });

  test('a rewrite that empties the buffer resets detached replay state', () {
    final io = FakeStdio()..columns = 40;
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(40, 12, split: false, drawInfoFrame: false),
      ansi: AnsiCapable.yes,
    );
    final r = ScrollingTextRegion(
      screen,
      bounds: const Rect(row: 0, col: 0, width: 30, height: 6),
    )..attach();
    r.detach();
    r.write('hidden line\n');
    r.attach();
    r.resetAfterClear();
    expect(r.debugDetachedBufferLength, 0);
    expect(r.debugDetachedDroppedLines, 0);
  });

  test('row-count-neutral rewrite re-emits only the rewritten rows', () {
    // A 5-row buffer (4 content rows + the reserved cursor row) filled with
    // five-row content leaves one row in history — the steady state where a
    // streaming block rewrite lands. Rewriting 2 tail rows with 2 new lines
    // (same row count) must emit exactly those rows; the pre-change behaviour
    // was a full-window repaint with every snapshot cleared.
    final io = FakeStdio()..columns = 40;
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(40, 12, split: false, drawInfoFrame: false),
      ansi: AnsiCapable.yes,
    );
    final r = ScrollingTextRegion(
      screen,
      bounds: const Rect(row: 0, col: 0, width: 30, height: 5),
    )..attach();
    for (var i = 1; i <= 5; i++) {
      r.write('row-$i\n');
    }
    // rows 1-4 in history, row-5 in the window; push one more so the window
    // holds 4 content rows and history holds 2 (full-window steady state).
    r.write('row-6\n');
    final historyBefore = r.debugHistoryLength;
    expect(historyBefore, greaterThan(0));

    // Rewrite the last two window rows in place (same count): 5 and 6 → E, F.
    final from = r.contentRows - 2;
    r.rewriteFrom(from, const [RegionLine('row-E'), RegionLine('row-F')]);

    final vt = VirtualTerminal(width: 40, height: 12);
    vt.feed(io.written.toString());
    io.written.clear();
    final visible = [for (var row = 0; row < 12; row++) vt.rowText(row)];
    final content = visible.map((row) => row.trimRight()).toList();
    expect(content.where((row) => row.isNotEmpty).toList(),
        ['row-2', 'row-3', 'row-4', 'row-E', 'row-F'],
        reason: 'the rewrite paints the new tail; the leading fill shows the '
            'history rows above it, byte-identical to a full redraw');
  });

  test('row-count-neutral rewrite writes less than a full repaint would', () {
    // The operation-count form of the guarantee: rewriting the same number of
    // rows must touch fewer cells than the full-window redraw the old code
    // ran. Count eraseCells payloads on the recorded backend.
    final backend = _CountingBackend();
    final screen = Screen.withBackend(
      backend: backend,
      io: FakeStdio(),
      layout: ScreenLayout.fromSize(80, 24, split: false),
      ansi: AnsiCapable.yes,
    )..redrawFrame();
    backend.resetCounters();

    final r = screen.chat;
    final rect = r.bounds;
    for (var i = 1; i <= 30; i++) {
      r.write('line ${i.toString().padLeft(3, '0')} ${'x' * 40}\n');
    }
    backend.resetCounters();

    // Rewrite the last two rows in place, same row count.
    final from = r.contentRows - 2;
    r.rewriteFrom(from, const [RegionLine('A'), RegionLine('B')]);

    final patchedErase = backend.erasedTotal;
    // The fast path writes only the two rewritten rows (suffix patches); the
    // leading history fill rows of the retained path repaint on first emit,
    // so allow two full row widths per window row as the ceiling. The old
    // behaviour (a full repaint on every rewrite) exceeded this by erasing
    // every window row's full width on this AND every subsequent rewrite.
    expect(patchedErase, lessThanOrEqualTo(2 * rect.width * 6),
        reason: 'in-place rewrite must patch, not repaint the window; '
            'erased $patchedErase cells, window width ${rect.width}');

    // The strong form: a SECOND identical rewrite (same content) must emit
    // nothing at all — snapshots are retained, so the repaint is a no-op.
    backend.resetCounters();
    r.rewriteFrom(from, const [RegionLine('A'), RegionLine('B')]);
    expect(backend.erasedTotal, 0,
        reason: 'an unchanged rewrite must skip entirely (snapshots retained)');
  });
}

class _CountingBackend implements TerminalBackend {
  final List<String> calls = [];
  int _frameDepth = 0;
  bool _flushPending = false;

  // No retained damage model in this fake; refresh is a no-op.
  @override
  void refresh() {}

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

  void resetCounters() => calls.clear();

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
  void parkCursor(int row, int col) {}
  @override
  void moveCursor(int row, int col) => calls.add('move($row,$col)');
  @override
  void eraseCells(int row, int col, int n) => calls.add('erase($row,$col,$n)');
  @override
  void writeText(String text) => calls.add('write(${text.length})');
  @override
  void saveCursor() {}
  @override
  void restoreCursor() {}
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
  @override
  bool get coalescesPaints => false;
  @override
  String colorize(String code, String text) => '\x1b[${code}m$text\x1b[0m';
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  int get terminalColumns => 80;
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
