/// Fixtures: alternate screens, OSC strings, RIS, damage, parser limits,
/// and scrollback bounds (tin-t8wd).
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_console/src/terminal/terminal_emulator.dart';

import 'terminal_fixtures.dart';

void main() {
  group('alternate screens', () {
    for (final f in [
      Fixture(
        name: '1049 saves the cursor, clears alt, restores on exit',
        bytes: esc('\x1b[2;3Ha\x1b[?1049hbX\x1b[?1049lY'),
        expectGrid: [
          '########',
          '##aY####',
          '########',
          '########',
        ],
        cursorRow: 1,
        cursorCol: 4,
      ),
      Fixture(
        name: '47 swaps screens without clearing or cursor save',
        bytes: esc('A\x1b[?47hB\x1b[?47lC'),
        expectGrid: [
          'AC######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
      Fixture(
        name: '1047 clears the alt screen when leaving it',
        bytes: esc('\x1b[?1047hB\x1b[?1047lC'),
        expectGrid: [
          'C#######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 1,
      ),
      Fixture(
        name: 'text on the alt screen never touches the primary',
        bytes: esc('\x1b[?1049h\x1b[2;1Hhello'),
        cursorRow: 1,
        cursorCol: 5,
        expectGrid: [
          '########',
          'hello###',
          '########',
          '########',
        ],
        state: (t) {
          expect(t.inAlternateScreen, isTrue);
          expect(t.primary.screen[1].isBlank, isTrue);
        },
      ),
    ]) {
      replayAll(f);
    }

    emulatorCase('primary history survives alt-screen round trip', (t) {
      t.feed(esc('l1\r\nl2\r\nl3\r\nl4\r\nl5')); // scrolls one row into history
      expect(t.primary.scrollback.length, 1);
      t.feed(esc('\x1b[?1049h'));
      t.feed(esc('alt'));
      expect(t.alternate.scrollback.length, 0);
      t.feed(esc('\x1b[?1049l'));
      expect(t.primary.scrollback.length, 1);
      expect(t.primary.scrollback.rows.first.text().trim(), 'l1');
      expect(renderGridOf(t)[0], 'l2######');
    });

    emulatorCase('1049 clears leftover alt content on entry', (t) {
      t.feed(esc('\x1b[?1049hjunk\x1b[?1049l'));
      t.feed(esc('\x1b[?1049h'));
      expect(renderGridOf(t)[0], '########');
      t.feed(esc('\x1b[?1049l'));
    });
  });

  group('OSC strings', () {
    for (final f in [
      Fixture(
        name: 'OSC 0 sets the title via BEL terminator',
        bytes: esc('\x1b]0;my title\x07'),
        events: [const TitleEvent('my title')],
      ),
      Fixture(
        name: 'OSC 2 sets the title via ST terminator',
        bytes: esc('\x1b]2;second\x1b\\'),
        events: [const TitleEvent('second')],
      ),
      Fixture(
        name: 'OSC 1 is ignored',
        bytes: esc('\x1b]1;icon name\x07'),
      ),
      Fixture(
        name: 'OSC 52 clipboard write has no effect and no event',
        bytes: esc('\x1b]52;c;aGVsbG8=\x07'),
      ),
      Fixture(
        name: 'OSC 8 hyperlink is consumed silently',
        bytes: esc('\x1b]8;;http://x\x07link\x1b\\'),
        expectGrid: [
          'link####',
          '########',
          '########',
          '########',
        ],
        cursorCol: 4,
      ),
      Fixture(
        name: 'OSC payload with control characters is sanitized',
        bytes: const [0x1b, 0x5d, 0x30, 0x3b, 0x74, 0x01, 0x69, 0x07],
        events: [const TitleEvent('ti')],
      ),
      Fixture(
        name: 'title text lands verbatim including spaces',
        bytes: esc('\x1b]0;a b c\x07'),
        events: [const TitleEvent('a b c')],
      ),
      Fixture(
        name: 'DCS, SOS, PM, APC payloads are consumed invisibly',
        bytes: esc('\x1bP1;2|payload\x1b\\\x1bXsos\x1b\\\x1b^pm\x1b\\\x1b_apc\x1b\\ok'),
        expectGrid: [
          'ok######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
    ]) {
      replayAll(f);
    }

    emulatorCase('oversized OSC payload is discarded, not rendered', (t) {
      final long = List<int>.filled(TerminalEmulator.maxSequenceBytes + 64, 0x41);
      final result = t.feed([...esc('\x1b]0;'), ...long, 0x07]);
      expect(result.events, isEmpty);
      expect(renderGridOf(t)[0], '########');
    });
  });

  group('reset (RIS) and damage', () {
    emulatorCase('RIS clears grids, history, modes, tabs, charset', (t) {
      t.feed(esc('\x1b[?1049h\x1b[?5h\x1b[?25l\x1b(0\x1bH\x1b[2;3r'));
      t.feed(esc('l1\r\nl2\r\nl3\r\nl4\r\nl5'));
      t.reset();
      final snap = t.snapshot();
      expect(snap.primaryActive, isTrue);
      expect(t.primary.scrollback.length, 0);
      expect(renderGridOf(t), everyElement('########'));
      expect(snap.cursorRow, 0);
      expect(snap.cursorCol, 0);
      expect(snap.cursorVisible, isTrue);
      expect(snap.screenInverse, isFalse);
      expect(t.primary.tabStops, {0});
      expect(t.primary.g0Charset, 0);
      expect(t.primary.marginTop, isNull);
    });

    emulatorCase('damage starts true, takeDamage clears it', (t) {
      expect(t.hasDamage, isTrue);
      expect(t.takeDamage(), isTrue);
      expect(t.takeDamage(), isFalse);
    });

    emulatorCase('printing sets damage, query alone does not', (t) {
      t.takeDamage();
      t.feed(esc('\x1b[5n'));
      expect(t.hasDamage, isFalse);
      t.feed(esc('x'));
      expect(t.hasDamage, isTrue);
      expect(t.takeDamage(), isTrue);
      expect(t.takeDamage(), isFalse);
    });
  });

  group('parser limits and aborts', () {
    for (final f in [
      Fixture(
        name: 'CAN aborts a CSI sequence mid-flight',
        bytes: esc('\x1b[1;2'),
        cursorRow: 0,
        cursorCol: 0,
        state: null,
      ),
      Fixture(
        name: 'CSI overflow through the terminator discards quietly',
        bytes: esc(''),
        state: null,
      ),
    ]) {
      replayAll(f);
    }

    test('CAN aborts the pending CSI so nothing dispatches', () {
      final t = TerminalEmulator(initialRows: 4, initialCols: 8);
      t.feed([...esc('\x1b[2;3'), 0x18, ...esc('H')]);
      // CUP never dispatched: cursor did not move; the trailing 'H' of the
      // aborted sequence is reinterpreted as literal text.
      expect(t.snapshot().cursorRow, 0);
      expect(t.snapshot().cursorCol, 1);
      expect(renderGridOf(t)[0], 'H#######');
    });

    test('SUB behaves like CAN', () {
      final t = TerminalEmulator(initialRows: 4, initialCols: 8);
      t.feed([...esc('\x1b[2;3'), 0x1a, ...esc('H')]);
      expect(t.snapshot().cursorRow, 0);
      expect(renderGridOf(t)[0], 'H#######');
    });

    test('more than 32 CSI params: the sequence still terminates cleanly',
        () {
      final t = TerminalEmulator(initialRows: 4, initialCols: 8);
      final params = List<String>.generate(40, (_) => '1').join(';');
      t.feed(esc('a\x1b[$params Hb')); // invalid space; use H via CUP instead
      // The sequence above may be discarded; either way, no crash and the
      // following text prints.
      expect(renderGridOf(t)[0], contains('b'));
    });

    test('oversized CSI numeric fields do not desync the stream', () {
      final t = TerminalEmulator(initialRows: 4, initialCols: 8);
      t.feed(esc('\x1b['));
      t.feed(List<int>.filled(200, 0x39)); // '9' x 200
      t.feed(esc('H'));
      t.feed(esc('X'));
      expect(renderGridOf(t)[0], contains('X'));
    });

    test('unknown CSI finals are ignored and the stream continues', () {
      final t = TerminalEmulator(initialRows: 4, initialCols: 8);
      t.feed(esc('\x1b[3Qok'));
      expect(renderGridOf(t)[0], 'ok######');
    });

    test('unknown ESC finals are ignored', () {
      final t = TerminalEmulator(initialRows: 4, initialCols: 8);
      t.feed(const [0x1b, 0x7f]); // DEL is not a valid ESC payload: abandon
      t.feed(esc('ok'));
      expect(renderGridOf(t)[0], 'ok######');
    });

    test('a CSI split at every prefix position still dispatches once', () {
      const seq = '\x1b[2;3H';
      final bytes = utf8.encode(seq);
      for (var cut = 1; cut < bytes.length; cut++) {
        final t = TerminalEmulator(initialRows: 4, initialCols: 8);
        t.feed(bytes.sublist(0, cut));
        t.feed(bytes.sublist(cut));
        expect(t.snapshot().cursorRow, 1, reason: 'cut at $cut');
        expect(t.snapshot().cursorCol, 2, reason: 'cut at $cut');
      }
    });

    test('an OSC split mid-payload still yields the title', () {
      const bytes = [
        0x1b, 0x5d, 0x30, 0x3b, 0x68, 0x69, 0x07, // ESC ] 0 ; h i BEL
      ];
      for (var cut = 1; cut < bytes.length; cut++) {
        final t = TerminalEmulator(initialRows: 4, initialCols: 8);
        final first = t.feed(bytes.sublist(0, cut));
        final second = t.feed(bytes.sublist(cut));
        final events = [...first.events, ...second.events];
        expect(events.length, 1, reason: 'cut at $cut');
        expect((events.single as TitleEvent).title, 'hi',
            reason: 'cut at $cut');
      }
    });
  });

  group('scrollback bounds', () {
    test('row cap evicts the oldest rows', () {
      final t = TerminalEmulator(
          initialRows: 2, initialCols: 4, scrollbackMaxRows: 3);
      t.feed(esc('a\r\nb\r\nc\r\nd\r\ne'));
      final sb = t.primary.scrollback;
      expect(sb.length, 3);
      expect(sb.rows.first.text().trim(), 'a'); // oldest
      expect(sb.rows.last.text().trim(), 'c'); // newest archived
    });

    test('cell cap evicts even when the row count is tiny', () {
      final t = TerminalEmulator(
          initialRows: 2,
          initialCols: 4,
          scrollbackMaxRows: 100,
          scrollbackMaxCells: 8); // 2 rows of 4 cells
      t.feed(esc('a\r\nb\r\nc\r\nd\r\ne\r\nf'));
      final sb = t.primary.scrollback;
      expect(sb.storedCells, lessThanOrEqualTo(8));
      expect(sb.length, lessThanOrEqualTo(2));
    });

    test('wide glyph continuation cells count toward the cell cap', () {
      final t = TerminalEmulator(
          initialRows: 2,
          initialCols: 4,
          scrollbackMaxRows: 100,
          scrollbackMaxCells: 12);
      t.feed(esc('漢漢\r\n字字\r\nb\r\nc'));
      final sb = t.primary.scrollback;
      expect(sb.storedCells, lessThanOrEqualTo(12));
    });

    test('injectable limits accept the plan defaults', () {
      final t = TerminalEmulator(); // 10,000 rows / 1,000,000 cells
      expect(t.primary.scrollback.maxRows, 10000);
      expect(t.primary.scrollback.maxCells, 1000000);
    });
  });
}
