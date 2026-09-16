/// Fixtures: plain text, UTF-8, and the C0 control family (tin-t8wd).
///
/// Every expected grid is hand-written here and is the oracle; the emulator
/// output is compared against it, never the reverse.
library;

import 'package:test/test.dart';
import 'package:tina_console/src/terminal/terminal_emulator.dart';

import 'terminal_fixtures.dart';

void main() {
  group('text and C0 controls', () {
    for (final f in [
      Fixture(
        name: 'plain ASCII lands left to right',
        bytes: esc('hi'),
        expectGrid: [
          'hi######',
          '########',
          '########',
          '########',
        ],
        cursorRow: 0,
        cursorCol: 2,
      ),
      Fixture(
        name: 'LF moves down keeping the column',
        bytes: esc('ab\nc'),
        expectGrid: [
          'ab######',
          '##c#####',
          '########',
          '########',
        ],
        cursorRow: 1,
        cursorCol: 3,
      ),
      Fixture(
        name: 'CR returns to column zero',
        bytes: esc('abc\rZ'),
        expectGrid: [
          'Zbc#####',
          '########',
          '########',
          '########',
        ],
        cursorRow: 0,
        cursorCol: 1,
      ),
      Fixture(
        name: 'CR LF starts the next row at column zero',
        bytes: esc('ab\r\ncd'),
        expectGrid: [
          'ab######',
          'cd######',
          '########',
          '########',
        ],
        cursorRow: 1,
        cursorCol: 2,
      ),
      Fixture(
        name: 'BS moves back and overwrite replaces',
        bytes: esc('ab\bX'),
        expectGrid: [
          'aX######',
          '########',
          '########',
          '########',
        ],
        cursorRow: 0,
        cursorCol: 2,
      ),
      Fixture(
        name: 'BS at column zero stays put',
        bytes: esc('\ba'),
        expectGrid: [
          'a#######',
          '########',
          '########',
          '########',
        ],
        cursorRow: 0,
        cursorCol: 1,
      ),
      Fixture(
        name: 'HT goes to the last column when no stop remains in the row',
        bytes: esc('a\tb'),
        expectGrid: [
          'a######b',
          '########',
          '########',
          '########',
        ],
        cursorCol: 7,
        pendingWrap: true,
      ),
      Fixture(
        name: 'HT from the last column stays there and the write overwrites',
        bytes: esc('12345678\tX'),
        expectGrid: [
          '1234567X',
          '########',
          '########',
          '########',
        ],
        cursorCol: 7,
        pendingWrap: true,
      ),
      Fixture(
        name: 'BEL raises a bell event, not text',
        bytes: esc('a\x07b'),
        expectGrid: [
          'ab######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
        events: [const BellEvent()],
      ),
      Fixture(
        name: 'VT and FF behave like LF',
        bytes: esc('ab\x0bc\x0cd'),
        expectGrid: [
          'ab######',
          '##c#####',
          '###d####',
          '########',
        ],
        cursorRow: 2,
        cursorCol: 4,
      ),
      Fixture(
        name: 'DEL (0x7f) is ignored',
        bytes: esc('a\x7fb'),
        expectGrid: [
          'ab######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
      Fixture(
        name: 'NUL and other low C0 are ignored',
        bytes: esc('a\x00\x01\x02b'),
        expectGrid: [
          'ab######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
    ]) {
      replayAll(f);
    }

    group('UTF-8', () {
      for (final f in [
        Fixture(
          name: 'two-byte sequence decodes',
          bytes: [0x61, 0xc3, 0xa9], // a é
          expectGrid: [
            'aé######',
            '########',
            '########',
            '########',
          ],
          cursorCol: 2,
        ),
        Fixture(
          name: 'three-byte sequence decodes',
          bytes: [0xe2, 0x82, 0xac], // €
          expectGrid: [
            '€#######',
            '########',
            '########',
            '########',
          ],
          cursorCol:  1,
          pendingWrap: false,
        ),
        Fixture(
          name: 'four-byte sequence decodes (wide, two cells)',
          bytes: [0xf0, 0x9f, 0x91, 0x8b], // 👋
          expectGrid: [
            '👋.######',
            '########',
            '########',
            '########',
          ],
          cursorCol: 2,
        ),
        Fixture(
          name: 'truncated lead byte stays pending until more bytes arrive',
          bytes: [0x61, 0xc3, 0xa9], // a é — the é arrives whole
          expectGrid: [
            'aé######',
            '########',
            '########',
            '########',
          ],
          cursorCol: 2,
        ),
        Fixture(
          name: 'overlong encoding becomes two replacements',
          bytes: [0xc0, 0xaf], // overlong '/'
          expectGrid: [
            '\u{fffd}\u{fffd}######',
            '########',
            '########',
            '########',
          ],
          cursorCol: 2,
        ),
        Fixture(
          name: 'surrogate encoding becomes one replacement',
          bytes: [0xed, 0xa0, 0x80], // CESU-8 D800
          expectGrid: [
            '\u{fffd}#######',
            '########',
            '########',
            '########',
          ],
          cursorCol: 1,
        ),
        Fixture(
          name: 'lone continuation byte becomes replacement',
          bytes: [0x80],
          expectGrid: [
            '\u{fffd}#######',
            '########',
            '########',
            '########',
          ],
          cursorCol: 1,
        ),
        Fixture(
          name: 'impossible lead byte becomes replacement, ASCII continues',
          bytes: [0xfe, 0x41],
          expectGrid: [
            '\u{fffd}A######',
            '########',
            '########',
            '########',
          ],
          cursorCol: 2,
        ),
        Fixture(
          name: 'control interrupts a partial sequence: replacement, then control',
          bytes: [0x61, 0xc3, 0x0a, 0x62],
          expectGrid: [
            'a\u{fffd}######',
            '##b#####',
            '########',
            '########',
          ],
          cursorRow: 1,
          cursorCol: 3,
        ),
        Fixture(
          name: 'CJK wide glyph occupies two cells',
          bytes: [0x61, 0xe6, 0xbc, 0xa2], // a 漢
          expectGrid: [
            'a漢.#####',
            '########',
            '########',
            '########',
          ],
          cursorCol: 3,
        ),
        Fixture(
          name: 'combining mark joins the base cell as a decomposed cluster',
          bytes: [0x65, 0xcc, 0x81], // e + combining acute
          expectGrid: [
            'e\u{0301}#######',
            '########',
            '########',
            '########',
          ],
          cursorCol: 1,
          state: (t) {
            final cell = t.snapshot().screen[0].cells[0];
            expect(cell.text, 'e');
            expect(cell.combining, ['\u{0301}']);
            expect(cell.cluster, 'e\u{0301}');
          },
        ),
      ]) {
        replayAll(f);
      }

      emulatorCase('wide glyph at the last column wraps whole', (t) {
        t.feed(esc('\x1b[1;8H')); // row 1, col 8 (1-based) — last column
        t.feed([0xe6, 0xbc, 0xa2]); // 漢
        final snap = t.snapshot();
        expect(snap.cursorRow, 1);
        expect(snap.cursorCol, 2); // after the pair on the new row
        expect(renderGridOf(t)[0], '#######$blank');
        expect(renderGridOf(t)[1], '漢.######');
      });

      emulatorCase('DECAWM off overwrites the last column in place', (t) {
        t.feed(esc('\x1b[?7l')); // autowrap off
        t.feed(esc('abcdefghij'));
        final snap = t.snapshot();
        expect(snap.cursorCol, t.cols - 1);
        expect(renderGridOf(t)[0], 'abcdefgj'); // 'j' overwrote 'h'
        expect(renderGridOf(t)[1], '########');
      });

      emulatorCase('pending wrap only fires on the next printed glyph', (t) {
        t.feed(esc('abcdefgh')); // fills row 0, cursor pending-wrap
        t.feed(esc('\r')); // CR cancels the pending wrap, column 0
        t.feed(esc('X')); // no wrap: overwrite at column 0
        expect(renderGridOf(t)[0], 'Xbcdefgh');
        expect(t.snapshot().cursorRow, 0);
      });

      emulatorCase('wrap after a full row lands at row+1 col 0', (t) {
        t.feed(esc('abcdefghij')); // 10 chars on an 8-wide grid
        final snap = t.snapshot();
        expect(snap.cursorRow, 1);
        expect(snap.cursorCol, 2);
        expect(renderGridOf(t)[0], 'abcdefgh');
        expect(renderGridOf(t)[1], 'ij######');
      });

      emulatorCase('LF at the bottom row scrolls the screen up', (t) {
        t.feed(esc('\x1b[4;1Hbottom\n'));
        expect(t.snapshot().cursorRow, 3);
        expect(renderGridOf(t)[0], '########'); // displaced top row is gone
        expect(renderGridOf(t)[3], '########'); // LF left the new row blank
      });

      emulatorCase('a written row scrolls into history with its text', (t) {
        t.feed(esc('l1\r\nl2\r\nl3\r\nl4\r\nl5'));
        final sb = t.primary.scrollback;
        expect(sb.length, 1);
        expect(sb.rows.first.text().trim(), 'l1');
        expect(renderGridOf(t)[0], 'l2######');
        expect(renderGridOf(t)[3], 'l5######');
      });

      emulatorCase('blank rows never enter history', (t) {
        t.feed(esc('\n\n\n\n\n\n\n\n\n\n\n\n'));
        expect(t.primary.scrollback.length, 0);
      });
    });
  });
}

List<String> renderGridOf(TerminalEmulator t) => [
      for (final row in t.snapshot().screen)
        [
          for (final cell in row.cells)
            if (cell.isContinuation)
              '.'
            else if (cell.text.isEmpty)
              blank
            else
              cell.cluster,
        ].join(),
    ];
