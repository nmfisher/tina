import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

// Phase 2A acceptance tests: the chat row model stores append-only segments
// with a cached flattened value, so streaming many small chunks no longer
// rebuilds the row string once per chunk. These tests prove (1) rendered
// output identical to the single-write path, (2) grapheme/surrogate safety
// when a chunk boundary falls inside a multi-code-unit sequence, (3) bounded
// segment count under sustained appends (the allocation invariant), and (4)
// that the isEmpty/isNotEmpty + bottom-alignment behavior is unchanged.
//
// We compare rendered cell grids (via VirtualTerminal), not raw byte streams:
// the single-write and per-chunk paths issue different cursor-positioning
// sequences even when the final cells are identical, so byte comparison would
// be brittle. The invariant that matters is that the user sees the same text.
//
// Setup mirrors scrolling_text_region_test.dart: FakeStdio + VirtualTerminal,
// redraw the frame once, feed it into the VT, then clear `io.written` so each
// test observes only its own writes.

void main() {
  late FakeStdio io;
  late Screen screen;
  late VirtualTerminal vt;
  late ScreenLayout layout;

  setUp(() {
    io = FakeStdio();
    layout = ScreenLayout.fromSize(100, 24);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
  });

  /// Build a fresh screen + VT in the same starting state as [setUp], so two
  /// paths can be compared cell-for-cell on independent screens.
  ({Screen screen, VirtualTerminal vt, FakeStdio io}) _fresh() {
    final io = FakeStdio();
    final screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(100, 24),
      ansi: AnsiCapable.yes,
    );
    final vt = VirtualTerminal(width: 100, height: 24);
    screen.redrawFrame();
    vt.feed(io.written.toString());
    io.written.clear();
    return (screen: screen, vt: vt, io: io);
  }

  test('many small appends render identically to one big write', () {
    // The same 50-character string written one char at a time vs. all at once
    // must leave the same cells on the screen. This is the core 2A safety
    // guarantee: segment storage materializes the same string, just lazily.
    final chars = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMN';

    final whole = _fresh();
    whole.screen.chat.write(chars);
    whole.vt.feed(whole.io.written.toString());

    for (final c in chars.split('')) {
      screen.chat.write(c);
    }
    vt.feed(io.written.toString());

    for (var r = 0; r < 24; r++) {
      expect(vt.rowText(r), whole.vt.rowText(r),
          reason: 'row $r differs between per-chunk and single-write');
    }
  });

  test('surrogate pair split across chunks renders intact', () {
    // '👨' is U+1F468, a surrogate pair in UTF-16. Writing it as two separate
    // write() calls splits the pair across two segments. Joining the segments
    // must restore the same rendered cells as writing the whole emoji once.
    final emoji = '👨';
    final high = emoji.substring(0, 1); // leading surrogate
    final low = emoji.substring(1, 2); // trailing surrogate

    final whole = _fresh();
    whole.screen.chat.write(emoji);
    whole.vt.feed(whole.io.written.toString());

    screen.chat.write(high);
    screen.chat.write(low);
    vt.feed(io.written.toString());

    for (var r = 0; r < 24; r++) {
      expect(vt.rowText(r), whole.vt.rowText(r),
          reason: 'row $r differs: a surrogate pair split across two segments '
              'must rejoin to the same cells as a single write');
    }
  });

  test('combining mark split across chunks renders intact', () {
    // A base char 'e' + combining acute (U+0301), written as two chunks vs.
    // one. The joined string must render the same cells. Both paths use the
    // decomposed form (two code points) so the only variable is chunk
    // granularity — not Unicode normalization.
    const decomposed = "e\u{0301}";

    final whole = _fresh();
    whole.screen.chat.write(decomposed);
    whole.vt.feed(whole.io.written.toString());

    screen.chat.write('e');
    screen.chat.write("\u{0301}");
    vt.feed(io.written.toString());

    for (var r = 0; r < 24; r++) {
      expect(vt.rowText(r), whole.vt.rowText(r),
          reason: 'row $r differs: a base char + combining mark split across '
              'chunks must rejoin');
    }
  });

  test('bounded segment count under sustained single-char appends', () {
    // 500 single-char appends on one row. Without compaction the segment list
    // would grow to 500; with compaction it stays bounded at
    // segmentCompactThreshold. This is the deterministic linear-allocation
    // proof — the row's retained-object count is independent of chunk count.
    //
    // Use a wide, non-split layout so 500 chars fit on a single row (no wrap,
    // no scroll) and all appends land on row 0 of the buffer.
    final wide = ScreenLayout.fromSize(1000, 24, split: false);
    final wideIo = FakeStdio();
    final wideScreen = Screen(io: wideIo, layout: wide, ansi: AnsiCapable.yes)
      ..redrawFrame();
    for (var i = 0; i < 500; i++) {
      wideScreen.chat.write('x');
    }
    // Row 0 of the buffer holds the 500-char run (bottom-aligned to the last
    // content row, but the buffer index for the first content row is 0).
    final segCount = wideScreen.chat.debugSegmentCount(0);
    expect(segCount, lessThanOrEqualTo(64),
        reason: 'segment count must stay bounded under compaction; got $segCount');
    // And the row still reconstructs to a non-empty run.
    expect(segCount, greaterThan(0));
  });

  test('isEmpty/isNotEmpty: fresh row empty, after append non-empty', () {
    // The :189 / :333 call-site changes swapped `.text.isEmpty` for `.isEmpty`
    // and `.text.isNotEmpty` for `.isNotEmpty`. A partially-filled region must
    // still bottom-align: with one short write, the content sits on the last
    // content row and the rows above stay blank.
    screen.chat.write('hi');
    vt.feed(io.written.toString());
    final bottomRow = layout.chat.row + layout.chat.height - 1;
    final aboveRow = bottomRow - 1;
    expect(vt.charAt(bottomRow, layout.chat.col), 'h');
    expect(vt.charAt(bottomRow, layout.chat.col + 1), 'i');
    // The row above the single content row is still blank (bottom-aligned).
    expect(vt.charAt(aboveRow, layout.chat.col), ' ',
        reason: 'a single short write bottom-aligns, leaving the row above blank');
  });

  test('scrollback contents unchanged after compaction', () {
    // Force compaction (many appends) AND scrolling (more lines than height),
    // then assert the visible tail matches writing the same lines whole. This
    // guards that compaction + scroll together don't corrupt scrollback.
    final lines = <String>[];
    for (var i = 0; i < 60; i++) {
      // Each line is long enough to be its own row but short enough to fit the
      // 98-col chat width without wrapping, so line N maps to a distinct row.
      lines.add('line-${i.toString().padLeft(3, '0')}-xxxxxxxxxxxxxxxxxx');
    }

    // Write each line whole (one segment) for the reference output.
    final whole = _fresh();
    for (final line in lines) {
      whole.screen.chat.writeln(line);
    }
    whole.vt.feed(whole.io.written.toString());

    // Write each line one char at a time (many segments, triggers compaction).
    for (final line in lines) {
      for (final c in line.split('')) {
        screen.chat.write(c);
      }
      screen.chat.write('\n');
    }
    vt.feed(io.written.toString());

    // The visible chat content rows must match between the two paths.
    for (var r = 0; r < 24; r++) {
      expect(vt.rowText(r), whole.vt.rowText(r),
          reason: 'row $r differs after compaction+scroll');
    }
  });
}
