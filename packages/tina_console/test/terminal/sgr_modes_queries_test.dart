/// Fixtures: SGR attributes, DEC modes, DSR/DA queries, character sets.
/// Hand-written grids are the oracle; every fixture replays three ways.
library;

import 'package:test/test.dart';
import 'package:tina_console/src/terminal/terminal_emulator.dart';

import 'terminal_fixtures.dart';

void main() {
  group('SGR', () {
    for (final f in [
      Fixture(
        name: 'bold applies to following text',
        bytes: esc('\x1b[1ma'),
        cursorCol: 1,
        state: (t) {
          expect(t.snapshot().screen[0].cells[0].attributes.bold, isTrue);
        },
      ),
      Fixture(
        name: 'SGR 0 resets attributes mid-stream',
        bytes: esc('\x1b[1;4;31mb\x1b[0ma'),
        cursorCol: 2,
        state: (t) {
          expect(t.snapshot().screen[0].cells[0].attributes.bold, isTrue);
          expect(t.snapshot().screen[0].cells[0].attributes.underline, isTrue);
          expect(t.snapshot().screen[0].cells[0].attributes.fg?.index, 1);
          expect(t.snapshot().screen[0].cells[1].attributes.isPlain, isTrue);
        },
      ),
      Fixture(
        name: 'selective reset 22 clears bold and faint only',
        bytes: esc('\x1b[1;2;3;31mb\x1b[22mc'),
        cursorCol: 2,
        state: (t) {
          final b = t.snapshot().screen[0].cells[0].attributes;
          expect(b.bold, isTrue);
          expect(b.faint, isTrue);
          expect(b.italic, isTrue);
          final c = t.snapshot().screen[0].cells[1].attributes;
          expect(c.bold, isFalse);
          expect(c.faint, isFalse);
          expect(c.italic, isTrue);
          expect(c.fg?.index, 1);
        },
      ),
      Fixture(
        name: 'selective resets 23/24/27 clear their own flag only',
        bytes: esc('\x1b[3;4;7;31mb\x1b[23;24;27mc'),
        cursorCol: 2,
        state: (t) {
          final c = t.snapshot().screen[0].cells[1].attributes;
          expect(c.italic, isFalse);
          expect(c.underline, isFalse);
          expect(c.inverse, isFalse);
          expect(c.fg?.index, 1);
        },
      ),
      Fixture(
        name: '39/49 restore default colours',
        bytes: esc('\x1b[31;41mb\x1b[39;49mc'),
        cursorCol: 2,
        state: (t) {
          expect(t.snapshot().screen[0].cells[0].attributes.fg?.index, 1);
          expect(t.snapshot().screen[0].cells[0].attributes.bg?.index, 1);
          expect(t.snapshot().screen[0].cells[1].attributes.fg, isNull);
          expect(t.snapshot().screen[0].cells[1].attributes.bg, isNull);
        },
      ),
      Fixture(
        name: '256-colour params land on currentAttrs',
        bytes: esc(''),
        state: (t) {
          t.feed(esc('\x1b[38;5;123;48;5;77m'));
          final attrs = t.primary.currentAttrs;
          expect(attrs.fg?.index, 123);
          expect(attrs.bg?.index, 77);
        },
      ),
      Fixture(
        name: '24-bit RGB params land on currentAttrs',
        bytes: esc(''),
        state: (t) {
          t.feed(esc('\x1b[38;2;10;20;30m'));
          final attrs = t.primary.currentAttrs;
          expect(attrs.fg?.rgb, (10 << 16) | (20 << 8) | 30);
        },
      ),
      Fixture(
        name: 'bright colours via aixterm range',
        bytes: esc('\x1b[91;104mX'),
        cursorCol: 1,
        state: (t) {
          expect(t.snapshot().screen[0].cells[0].attributes.fg?.index, 9);
          expect(t.snapshot().screen[0].cells[0].attributes.bg?.index, 12);
        },
      ),
      Fixture(
        name: 'empty SGR resets to plain',
        bytes: esc('\x1b[31m\x1b[m'),
        cursorCol: 0,
        state: (t) {
          expect(t.snapshot().screen[0].cells[0].attributes.isPlain, isTrue);
        },
      ),
      Fixture(
        name: 'unknown SGR codes are ignored without breaking the stream',
        bytes: esc('\x1b[99;1;777mX'),
        cursorCol: 1,
        expectGrid: [
          'X#######',
          '########',
          '########',
          '########',
        ],
        state: (t) {
          expect(t.snapshot().screen[0].cells[0].attributes.bold, isTrue);
        },
      ),
      Fixture(
        name: 'text written before any SGR is plain',
        bytes: esc('ab'),
        cursorCol: 2,
        state: (t) {
          expect(t.snapshot().screen[0].cells[0].attributes.isPlain, isTrue);
          expect(t.snapshot().screen[0].cells[1].attributes.isPlain, isTrue);
        },
      ),
      Fixture(
        name: 'wide glyph carries its attributes on the lead cell',
        cursorCol: 2,
        bytes: [0x1b, 0x5b, 0x34, 0x31, 0x6d, 0xe6, 0xbc, 0xa2], // [41m 漢
        state: (t) {
          expect(t.snapshot().screen[0].cells[0].attributes.bg?.index, 1);
          expect(t.snapshot().screen[0].cells[0].text, '漢');
          expect(t.snapshot().screen[0].cells[1].isContinuation, isTrue);
        },
      ),
    ]) {
      replayAll(f);
    }
  });

  group('modes', () {
    for (final f in [
      Fixture(
        name: 'DECTCEM hides and shows the cursor',
        bytes: esc('\x1b[?25l'),
        state: (t) {
          expect(t.snapshot().cursorVisible, isFalse);
        },
      ),
      Fixture(
        name: 'DECCKM and application keypad flip independently',
        bytes: esc('\x1b[?1h\x1b='),
        state: (t) {
          expect(t.primary.applicationCursorKeys, isTrue);
          expect(t.primary.applicationKeypad, isTrue);
        },
      ),
      Fixture(
        name: 'bracketed paste and focus reporting latch on',
        bytes: esc('\x1b[?2004h\x1b[?1004h'),
        state: (t) {
          expect(t.primary.bracketedPaste, isTrue);
          expect(t.primary.focusReporting, isTrue);
        },
      ),
      Fixture(
        name: 'DECAWM off stops pending-wrap at the last column',
        bytes: esc('\x1b[?7labcdefgh'),
        expectGrid: [
          'abcdefgh',
          '########',
          '########',
          '########',
        ],
        cursorCol: 7,
        pendingWrap: false,
      ),
      Fixture(
        name: 'DECSCNM toggles screen-wide inverse',
        bytes: esc('\x1b[?5h'),
        state: (t) {
          expect(t.snapshot().screenInverse, isTrue);
        },
      ),
    ]) {
      replayAll(f);
    }

    emulatorCase('IRM inserts cells on write', (t) {
      t.feed(esc('abcd'));
      t.feed(esc('\x1b[1;1H\x1b[4h'));
      t.feed(esc('XY'));
      expect(renderGridOf(t)[0], 'XYabcd##');
      t.feed(esc('\x1b[4l'));
      t.feed(esc('\x1b[1;1HZ'));
      expect(renderGridOf(t)[0], 'ZYabcd##');
    });
  });

  group('queries', () {
    for (final f in [
      Fixture(
        name: 'DSR 5 answers device status OK',
        bytes: esc('\x1b[5n'),
        replies: esc('\x1b[0n'),
      ),
      Fixture(
        name: 'DSR 6 answers cursor position 1-based',
        bytes: esc('\x1b[3;4H\x1b[6n'),
        cursorRow: 2,
        cursorCol: 3,
        replies: esc('\x1b[3;4R'),
      ),
      Fixture(
        name: 'DSR 6 defaults to the home position',
        bytes: esc('\x1b[6n'),
        replies: esc('\x1b[1;1R'),
      ),
      Fixture(
        name: 'DA1 answers the conservative vt220 class reply',
        bytes: esc('\x1b[c'),
        replies: esc('\x1b[?62;22c'),
      ),
      Fixture(
        name: 'secondary DA answers with a plain terminal id',
        bytes: esc('\x1b[>c'),
        replies: esc('\x1b[>0;10;1c'),
      ),
      Fixture(
        name: 'DECXCPR answers a prefixed CPR',
        bytes: esc('\x1b[?6n'),
        replies: esc('\x1b[?1;1R'),
      ),
    ]) {
      replayAll(f);
    }
  });

  group('character sets', () {
    for (final f in [
      Fixture(
        name: 'DEC line drawing maps q to horizontal rule',
        bytes: esc('\x1b(0qq'),
        expectGrid: [
          '──######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
      Fixture(
        name: 'DEC line drawing maps l/k/x to box corners and stem',
        bytes: esc('\x1b(0lqkx'),
        expectGrid: [
          '┌─┐│####',
          '########',
          '########',
          '########',
        ],
        cursorCol: 4,
      ),
      Fixture(
        name: 'SO selects G1 for line drawing, SI returns to G0',
        bytes: esc('\x1b)0\x0eq\x0fq'),
        expectGrid: [
          '─q######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 2,
      ),
      Fixture(
        name: 'ASCII designation clears the graphics set',
        bytes: esc('\x1b)0\x1b)B\x0eq'),
        expectGrid: [
          'q#######',
          '########',
          '########',
          '########',
        ],
        cursorCol: 1,
      ),
    ]) {
      replayAll(f);
    }
  });
}
