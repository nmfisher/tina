/// Fixtures: resize (crop/pad, no reflow, clamp, orphan healing) (tin-t8wd).
library;

import 'package:test/test.dart';
import 'package:tina_console/src/terminal/terminal_emulator.dart';

import 'terminal_fixtures.dart';

void main() {
  emulatorCase('shrinking drops bottom rows, keeps top rows', (t) {
    t.feed(esc('a\r\nb\r\nc\r\nd'));
    t.resize(2, 8);
    final snap = t.snapshot();
    expect(snap.rows, 2);
    expect(renderGridOf(t), ['a#######', 'b#######']);
  });

  emulatorCase('growing pads blank rows at the bottom', (t) {
    t.feed(esc('a\r\nb'));
    t.resize(6, 8);
    final snap = t.snapshot();
    expect(snap.rows, 6);
    expect(renderGridOf(t).sublist(0, 2), ['a#######', 'b#######']);
    expect(renderGridOf(t).sublist(2), everyElement('########'));
  });

  emulatorCase('shrinking columns crops without reflow', (t) {
    t.feed(esc('abcdefgh'));
    t.resize(4, 4);
    expect(renderGridOf(t), ['abcd', '####', '####', '####']);
    expect(t.snapshot().cursorCol, 3);
  });

  emulatorCase('growing columns pads with blanks', (t) {
    t.feed(esc('ab'));
    t.resize(4, 6);
    expect(renderGridOf(t), ['ab####', '######', '######', '######']);
  });

  emulatorCase('cursor clamps into the new bounds', (t) {
    t.feed(esc('\x1b[4;8H'));
    t.resize(2, 4);
    final snap = t.snapshot();
    expect(snap.cursorRow, 1);
    expect(snap.cursorCol, 3);
  });

  emulatorCase('resize resets margins and origin mode', (t) {
    t.feed(esc('\x1b[2;3r\x1b[?6h'));
    t.resize(4, 8);
    expect(t.primary.marginTop, isNull);
    expect(t.primary.marginBottom, isNull);
    expect(t.primary.originMode, isFalse);
  });

  emulatorCase('resize adds default tab stops in new columns', (t) {
    t.resize(4, 20);
    expect(t.primary.tabStops, containsAll(<int>[0, 8, 16]));
  });

  emulatorCase('shrinking keeps old tab stops beyond the new width', (t) {
    t.resize(4, 20); // stops 0,8,16
    t.resize(4, 10); // 16 now out of range; 8 stays (xterm-style)
    expect(t.primary.tabStops, contains(8));
  });

  emulatorCase('resize never invents history from cropped rows', (t) {
    t.feed(esc('a\r\nb\r\nc\r\nd'));
    t.resize(2, 8);
    expect(t.primary.scrollback.length, 0);
  });

  emulatorCase('resize heals a wide glyph whose tail was cropped', (t) {
    t.feed(esc('\x1b[1;8H')); // col 8 of 8: a wide glyph wraps to row 2
    t.feed([0xe6, 0xbc, 0xa2]); // 漢 lands on row 2, cols 1-2
    t.resize(4, 2);
    final row = t.snapshot().screen[1];
    expect(row.cells[0].text, '漢');
    expect(row.cells[1].isContinuation, isTrue);
  });

  emulatorCase('resize clears a continuation whose lead was cropped', (t) {
    t.feed(esc('\x1b[1;1H'));
    t.feed([0xe6, 0xbc, 0xa2]); // 漢 at cols 1-2 (lead col 0)
    t.resize(4, 1); // crop to one column: the tail dies
    final row = t.snapshot().screen[0];
    expect(row.cells[0].isBlank, isTrue);
  });

  emulatorCase('resize applies to both grids', (t) {
    t.feed(esc('\x1b[?1049h\x1b[2;1Halt'));
    t.resize(3, 5);
    expect(t.alternate.rows, 3);
    expect(t.alternate.cols, 5);
    expect(t.primary.rows, 3);
    expect(t.primary.cols, 5);
    expect(renderGridOf(t), ['#####', 'alt##', '#####']);
  });

  emulatorCase('resize marks damage', (t) {
    t.takeDamage();
    t.resize(3, 5);
    expect(t.hasDamage, isTrue);
  });

  test('zero geometry is rejected', () {
    final t = TerminalEmulator(initialRows: 4, initialCols: 8);
    expect(() => t.resize(0, 8), throwsArgumentError);
    expect(() => t.resize(4, 0), throwsArgumentError);
    expect(() => t.resize(-1, 8), throwsArgumentError);
  });

  test('an old saved cursor clamps into the new bounds', () {
    final t = TerminalEmulator(initialRows: 4, initialCols: 8);
    t.feed(esc('\x1b[4;8H\x1b7'));
    t.resize(2, 4);
    t.feed(esc('\x1b8'));
    final snap = t.snapshot();
    expect(snap.cursorRow, lessThan(2));
    expect(snap.cursorCol, lessThan(4));
  });
}
