/// Fixtures: cursor movement, margins, and insert/erase editing (tin-t8wd).
///
/// Hand-written grids are the oracle. Every fixture replays three ways
/// (whole, byte-by-byte, every split) via [replayAll].
library;

import 'package:test/test.dart';

import 'terminal_fixtures.dart';

void main() {
  group('cursor movement', () {
    for (final f in [
      Fixture(
        name: 'CUF moves right, clamped at the last column',
        bytes: esc('abc\x1b[5C'),
        expectGrid: [
          'abc#####',
          '########',
          '########',
          '########',
        ],
        cursorCol: 7,
      ),
      Fixture(
        name: 'CUF then CUB move without writing',
        bytes: esc('\x1b[5C\x1b[2D'),
        cursorCol: 3,
      ),
      Fixture(
        name: 'CUD then CUU clamps at the top',
        bytes: esc('\x1b[2B\x1b[3A'),
        cursorRow: 0,
      ),
      Fixture(
        name: 'CUP addresses 1-based row and column',
        bytes: esc('\x1b[3;5H'),
        cursorRow: 2,
        cursorCol: 4,
      ),
      Fixture(
        name: 'CUP clamps out-of-range coordinates',
        bytes: esc('\x1b[99;99H'),
        cursorRow: 3,
        cursorCol: 7,
      ),
      Fixture(
        name: 'HVP (CSI f) behaves like CUP',
        bytes: esc('\x1b[2;4f'),
        cursorRow: 1,
        cursorCol: 3,
      ),
      Fixture(
        name: 'CHA sets the column, keeping the row',
        bytes: esc('ab\x1b[5G'),
        expectGrid: [
          'ab######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 4,
      ),
      Fixture(
        name: 'VPA sets the row, keeping the column',
        bytes: esc('ab\x1b[3d'),
        expectGrid: [
          'ab######',
          '########',
          '########',
          '########',
        ],
        cursorRow: 2,
        cursorCol: 2,
      ),
      Fixture(
        name: 'CNL moves down to column zero',
        bytes: esc('ab\x1b[2E'),
        expectGrid: [
          'ab######',
          '########',
          '########',
          '########',
        ],
        cursorRow: 2,
        cursorCol: 0,
      ),
      Fixture(
        name: 'CPL moves up to column zero',
        bytes: esc('\x1b[3;1H\x1b[2F'),
        cursorRow: 0,
        cursorCol: 0,
      ),
      Fixture(
        name: 'IND (ESC D) steps down',
        bytes: esc('a\x1bD'),
        expectGrid: [
          'a#######',
          '########',
          '########',
          '########',
        ],
        cursorRow: 1,
        cursorCol: 1,
      ),
      Fixture(
        name: 'RI (ESC M) at the top scrolls content down',
        bytes: esc('a\x1bM'),
        expectGrid: [
          '########',
          'a#######',
          '########',
          '########',
        ],
        cursorRow: 0,
        cursorCol: 1,
      ),
      Fixture(
        name: 'RI between rows just steps up',
        bytes: esc('X\r\nY\x1bM'),
        expectGrid: [
          'X#######',
          'Y#######',
          '########',
          '########',
        ],
        cursorRow: 0,
        cursorCol: 1,
      ),
      Fixture(
        name: 'NEL (ESC E) is CR plus LF',
        bytes: esc('ab\x1bE'),
        expectGrid: [
          'ab######',
          '########',
          '########',
          '########',
        ],
        cursorRow: 1,
        cursorCol: 0,
      ),
      Fixture(
        name: 'DECSC/DECRC round-trips the cursor position',
        bytes: esc('\x1b[2;3Ha\x1b7\x1b[4;1Hb\x1b8c'),
        expectGrid: [
          '########',
          '##ac####',
          '########',
          'b#######',
        ],
        cursorRow: 1,
        cursorCol: 4,
      ),
      Fixture(
        name: 'CSI s / CSI u round-trips too',
        bytes: esc('ab\x1b[s\x1b[4;1H\x1b[uc'),
        expectGrid: [
          'abc#####',
          '########',
          '########',
          '########',
        ],
        cursorCol: 3,
      ),
    ]) {
      replayAll(f);
    }

    emulatorCase('DECRC out of a shrunken grid clamps into range', (t) {
      t.resize(4, 8);
      t.feed(esc('\x1b[4;8H\x1b7'));
      t.resize(2, 4);
      t.feed(esc('\x1b8'));
      final snap = t.snapshot();
      expect(snap.cursorRow, lessThan(2));
      expect(snap.cursorCol, lessThan(4));
    });
  });

  group('tabs', () {
    for (final f in [
      Fixture(
        name: 'HTS sets a stop that HT then finds',
        bytes: esc('\x1b[1;4H\x1bH\x1b[1;1H\tX'),
        expectGrid: [
          '###X####',
          '########',
          '########',
          '########',
        ],
        cursorCol: 4,
      ),
      Fixture(
        name: 'TBC 0 removes the stop under the cursor, stop 0 remains',
        bytes: esc('\x1b[1;4H\x1bH\x1b[1;1H\x1b[g\tX'),
        expectGrid: [
          '###X####',
          '########',
          '########',
          '########',
        ],
        cursorCol: 4,
      ),
      Fixture(
        name: 'CBT walks backwards over stops',
        bytes: esc('\x1b[1;5H\x1bH\x1b[1;7H\x1b[1Z'),
        cursorCol: 4,
      ),
    ]) {
      replayAll(f);
    }
  });

  group('editing', () {
    for (final f in [
      Fixture(
        name: 'ICH (CSI @) shifts text right from the cursor',
        bytes: esc('abcd\x1b[1;1H\x1b[2@'),
        expectGrid: [
          '##abcd##',
          '########',
          '########',
          '########',
        ],
        cursorCol: 0,
      ),
      Fixture(
        name: 'DCH (CSI P) deletes cells pulling text left',
        bytes: esc('abcd\x1b[1;1H\x1b[2P'),
        expectGrid: [
          'cd######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 0,
      ),
      Fixture(
        name: 'IL (CSI L) pushes lines down inside the screen',
        bytes: esc('a\r\nb\r\nc\x1b[1;1H\x1b[2L'),
        expectGrid: [
          '########',
          '########',
          'a#######',
          'b#######',
        ],
        cursorRow: 0,
      ),
      Fixture(
        name: 'DL (CSI M) pulls lines up',
        bytes: esc('a\r\nb\r\nc\r\nd\x1b[2;1H\x1b[1M'),
        expectGrid: [
          'a#######',
          'c#######',
          'd#######',
          '########',
        ],
        cursorRow: 1,
      ),
      Fixture(
        name: 'ECH (CSI X) blanks cells without moving the cursor',
        bytes: esc('abcdef\x1b[1;3H\x1b[2X'),
        expectGrid: [
          'ab##ef##',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
      Fixture(
        name: 'ED 0 erases from the cursor to the end of the screen',
        bytes: esc('abc\r\ndef\x1b[2;2H\x1b[J'),
        expectGrid: [
          'abc#####',
          'd#######',
          '########',
          '########',
        ],
        cursorRow: 1,
        cursorCol: 1,
      ),
      Fixture(
        name: 'ED 1 erases from the start of the screen to the cursor',
        bytes: esc('abcdef\r\nghijkl\x1b[2;3H\x1b[1J'),
        expectGrid: [
          '########',
          '###jkl##',
          '########',
          '########',
        ],
        cursorRow: 1,
        cursorCol: 2,
      ),
      Fixture(
        name: 'ED 2 blanks the screen and leaves the cursor alone',
        bytes: esc('abc\r\ndef\x1b[2J'),
        expectGrid: [
          '########',
          '########',
          '########',
          '########',
        ],
        cursorRow: 1,
        cursorCol: 3,
      ),
      Fixture(
        name: 'EL 0 erases from the cursor to the end of the line',
        bytes: esc('abcdef\x1b[1;3H\x1b[K'),
        expectGrid: [
          'ab######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
      Fixture(
        name: 'EL 1 erases from the start of the line to the cursor',
        bytes: esc('abcdef\x1b[1;3H\x1b[1K'),
        expectGrid: [
          '###def##',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
      Fixture(
        name: 'EL 2 blanks the whole line',
        bytes: esc('abcdef\x1b[2K'),
        expectGrid: [
          '########',
          '########',
          '########',
          '########',
        ],
        cursorCol: 6,
      ),
      Fixture(
        name: 'SU (CSI S) scrolls the screen up',
        bytes: esc('a\r\nb\r\nc\x1b[2S'),
        expectGrid: [
          'c#######',
          '########',
          '########',
          '########',
        ],
        cursorRow: 2,
        cursorCol: 1,
        scrollbackRows: 2,
      ),
      Fixture(
        name: 'SD (CSI T) scrolls the screen down',
        bytes: esc('a\x1b[1T'),
        expectGrid: [
          '########',
          'a#######',
          '########',
          '########',
        ],
        cursorRow: 0,
        cursorCol: 1,
      ),
    ]) {
      replayAll(f);
    }
  });

  group('margins (DECSTBM)', () {
    for (final f in [
      Fixture(
        name: 'DECSTBM homes the cursor and scrolls only the region',
        bytes: esc('\x1b[2;3r\x1b[3;1HX\r\nY\r\nZ'),
        expectGrid: [
          '########',
          'Y#######',
          'Z#######',
          '########',
        ],
        cursorRow: 2,
        cursorCol: 1,
        scrollbackRows: 0,
      ),
      Fixture(
        name: 'DECSTBM rejects a degenerate region',
        bytes: esc('\x1b[3;3r'),
        cursorRow: 0,
        cursorCol: 0,
        state: (t) {
          expect(t.primary.marginTop, isNull);
          expect(t.primary.marginBottom, isNull);
        },
      ),
      Fixture(
        name: 'IND at the region bottom scrolls the region, not history',
        bytes: esc('\x1b[2;3r\x1b[3;1HX\x1bD'),
        expectGrid: [
          '########',
          'X#######',
          '########',
          '########',
        ],
        cursorRow: 2,
        cursorCol: 1,
        scrollbackRows: 0,
      ),
      Fixture(
        name: 'RI at the region top scrolls the region down',
        bytes: esc('\x1b[2;3r\x1b[2;1H\x1bM'),
        expectGrid: [
          '########',
          '########',
          '########',
          '########',
        ],
        cursorRow: 1,
      ),
      Fixture(
        name: 'IL/DL below the margins do nothing',
        bytes: esc('a\r\nb\x1b[4;1H\x1b[2L\x1b[2M'),
        expectGrid: [
          'a#######',
          'b#######',
          '########',
          '########',
        ],
        cursorRow: 3,
      ),
    ]) {
      replayAll(f);
    }

    emulatorCase('DECOM addresses rows relative to the margin', (t) {
      t.feed(esc('\x1b[2;3r\x1b[?6h\x1b[1;1H'));
      expect(t.snapshot().cursorRow, 1); // margin top
      expect(t.snapshot().cursorCol, 0);
      t.feed(esc('\x1b[2;2H'));
      expect(t.snapshot().cursorRow, 2);
      // CPR is origin-relative (xterm).
      final result = t.feed(esc('\x1b[6n'));
      expect(result.replies, esc('\x1b[2;2R'));
    });

    emulatorCase('DECOM off restores absolute addressing', (t) {
      t.feed(esc('\x1b[2;3r\x1b[?6h\x1b[?6l\x1b[1;1H'));
      expect(t.snapshot().cursorRow, 0);
    });

    emulatorCase('full-screen scroll with margins still writes history', (t) {
      t.feed(esc('\x1b[1;4r')); // explicit full screen
      t.feed(esc('l1\r\nl2\r\nl3\r\nl4\r\nl5'));
      expect(t.primary.scrollback.length, 1);
      expect(t.primary.scrollback.rows.first.text().trim(), 'l1');
    });
  });
}
