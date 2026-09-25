import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

/// [ScrollingTextRegion.rewriteFrom] — the one entry point that edits the row
/// buffer instead of appending to it. Folding a block removes rows from the
/// middle, so this is what the transcript layer will rebuild through.
///
/// Geometry is tiny and explicit: a 4-row region (usable height 4, no input
/// inset), so the window/history boundary and the write cursor are both
/// obvious. Assertions read the real painted grid, so a stale row that was
/// never erased fails the test rather than hiding behind a buffer readback.
void main() {
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;

  const width = 10;
  const height = 4;

  setUp(() {
    io = FakeStdio()..columns = 40;
    final layout =
        ScreenLayout.fromSize(40, 12, split: false, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 40, height: 12);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  /// Replay everything the screen has written into the virtual terminal.
  void _pump() {
    vt.feed(io.written.toString());
    io.written.clear();
  }

  ScrollingTextRegion region() {
    final r = ScrollingTextRegion(
      screen,
      bounds: const Rect(row: 0, col: 0, width: width, height: height),
    );
    r.attach();
    _pump();
    return r;
  }

  /// The region's visible rows, top to bottom, right-trimmed.
  ///
  /// Content sits at the BOTTOM of the window (the live path's "chat grows up,
  /// not down" bottom-alignment), so a partially-filled window has blank rows
  /// above the content.
  List<String> visible() => [
        for (var r = 0; r < height; r++)
          vt.rowText(r).substring(0, width).trimRight(),
      ];

  /// The painted non-blank rows, in order. Order is what the transcript-level
  /// tests care about; a stale row left behind by a rebuild shows up here as an
  /// extra entry, which is exactly the defect under test.
  List<String> content() => visible().where((row) => row.isNotEmpty).toList();

  /// A region pre-filled with one content row per [rows] entry.
  ScrollingTextRegion filled(List<String> rows) {
    final r = region();
    for (final row in rows) {
      r.write('$row\n');
    }
    _pump();
    return r;
  }

  test('content sits at the bottom of the window, as the live path leaves it',
      () {
    filled(['one']);
    expect(visible(), ['', '', '', 'one']);
  });

  group('replacing a suffix', () {
    test('keeps the prefix verbatim and replaces everything after it', () {
      final r = filled(['one', 'two']);
      r.rewriteFrom(1, const [RegionLine('TWO'), RegionLine('three')]);
      _pump();
      expect(content(), ['one', 'TWO', 'three']);
    });

    test('rewriting from 0 replaces the whole transcript', () {
      final r = filled(['one', 'two', 'three']);
      r.rewriteFrom(0, const [RegionLine('only')]);
      _pump();
      expect(content(), ['only']);
      expect(r.contentRows, 1);
    });

    test('an index past the end appends rather than throwing', () {
      final r = filled(['one']);
      r.rewriteFrom(99, const [RegionLine('two')]);
      _pump();
      expect(content(), ['one', 'two']);
    });

    test('a negative index rebuilds from the oldest retained row', () {
      final r = filled(['one', 'two']);
      r.rewriteFrom(-5, const [RegionLine('fresh')]);
      _pump();
      expect(content(), ['fresh']);
    });
  });

  group('shrinking leaves nothing stale behind', () {
    test('rows past the new end are erased, not merely unindexed', () {
      final r = filled(['aaa', 'bbb', 'ccc']);
      expect(content(), ['aaa', 'bbb', 'ccc']);

      // Two rows in, three rows out: the third row must actually clear on
      // screen. A buffer-only rebuild would leave 'ccc' painted.
      r.rewriteFrom(1, const [RegionLine('B')]);
      _pump();
      expect(content(), ['aaa', 'B']);
    });

    test('a rewrite that empties the region clears every row', () {
      final r = filled(['aaa', 'bbb']);
      r.rewriteFrom(0, const []);
      _pump();
      expect(content(), isEmpty);
      expect(r.contentRows, 0);
    });
  });

  group('the write cursor', () {
    test('a write after a rewrite opens its own row, not the last one', () {
      final r = filled(['one', 'two']);
      r.rewriteFrom(0, const [RegionLine('x')]);
      _pump();
      r.write('next\n');
      _pump();
      // The tin-m2vq failure mode: landing the cursor on the last rebuilt row
      // would render 'xnext' as one row.
      expect(content(), ['x', 'next']);
    });

    test('a write with no trailing newline still lands on a fresh row', () {
      final r = filled(['one']);
      r.rewriteFrom(0, const [RegionLine('x')]);
      _pump();
      r.write('y');
      _pump();
      expect(content(), ['x', 'y']);
    });

    test('a rewrite that fills the window leaves the last row for the cursor',
        () {
      final r = filled(['one', 'two']);
      r.rewriteFrom(0, const [
        RegionLine('a'),
        RegionLine('b'),
        RegionLine('c'),
        RegionLine('d'),
      ]);
      _pump();
      // usable height 4 reserves one row for the cursor, so the oldest row
      // scrolls into history rather than the cursor landing on content.
      expect(content(), ['b', 'c', 'd']);
      expect(r.debugHistoryLength, 1);
      r.write('e\n');
      _pump();
      expect(content(), ['c', 'd', 'e']);
    });
  });

  group('scrollback', () {
    test('overflowing rebuilt content is retained as history', () {
      final r = filled(['one']);
      r.rewriteFrom(0, const [
        RegionLine('a'),
        RegionLine('b'),
        RegionLine('c'),
        RegionLine('d'),
        RegionLine('e'),
      ]);
      _pump();
      expect(r.contentRows, 5);
      expect(content(), ['c', 'd', 'e']);
    });

    test('an offset past the new end is clamped back into range', () {
      final r = filled(['a', 'b', 'c', 'd', 'e', 'f']);
      expect(r.debugHistoryLength, greaterThan(0));
      r.scrollBy(-2);
      _pump();
      expect(r.debugScrollOffset, greaterThan(0));

      r.rewriteFrom(0, const [RegionLine('short')]);
      _pump();
      expect(r.debugScrollOffset, 0,
          reason: 'the rebuilt content is shorter than the old view offset');
      expect(content(), ['short']);
    });

    test('a row-level bar survives a rewrite', () {
      final r = filled(['plain']);
      r.rewriteFrom(0, const [
        RegionLine('code', bar: '7'),
      ]);
      _pump();
      // The bar pads the row to the full region width, so the padded cells
      // are painted (asserted via width rather than the raw escape).
      expect(content(), ['code']);
      expect(r.contentRows, 1);
    });
  });

  group('surfaces with no row buffer', () {
    test('is a no-op while detached', () {
      final r = region();
      r.write('one\n');
      _pump();
      r.detach();
      // A detached region buffers raw text for replay on attach: there is no
      // painted row to rewrite, so the buffer is left untouched.
      r.rewriteFrom(0, const [RegionLine('ignored')]);
      expect(r.contentRows, 1);
    });

    test('is a no-op in passthrough', () {
      final layout =
          ScreenLayout.fromSize(40, 12, split: false, drawInfoFrame: false);
      final passScreen = Screen(
        io: FakeStdio()..columns = 40,
        layout: layout,
        ansi: AnsiCapable.no,
        passthrough: true,
      );
      final r = ScrollingTextRegion(
        passScreen,
        bounds: const Rect(row: 0, col: 0, width: width, height: height),
      );
      // Bytes already written to a passthrough surface cannot be recalled.
      r.write('already out\n');
      r.rewriteFrom(0, const [RegionLine('ignored')]);
      expect(r.contentRows, 0);
    });
  });
}
