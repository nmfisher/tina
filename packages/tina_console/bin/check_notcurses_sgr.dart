// SGR pass-through verification for the notcurses rendering backend.
//
// Answers: when tina_console hands `\x1b[31mhello\x1b[0m` to
// `ncplane_putstr_yx`, does notcurses interpret the embedded SGR codes
// and apply them as cell styling, or does it write each byte as a glyph?
//
// Runs three cases against a real libnotcurses, captures the putStrYX
// return code and the contents/styling of the resulting cells, then
// prints a verdict after stopping notcurses (terminal restored).
//
// Run from the tina_console package directory:
//   dart run bin/check_notcurses_sgr.dart
//
// Requires libnotcurses installed (Linux: libnotcurses.so;
// macOS: libnotcurses.dylib).

import 'dart:io';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;

const _plainText = 'hello';
const _sgrText = '\x1b[31mhello\x1b[0m';
const _redRgb = 0xff0000;

class _CellSnapshot {
  final int row;
  final int col;
  final String egc;
  final int stylemask;
  final int channels;
  _CellSnapshot(this.row, this.col, this.egc, this.stylemask, this.channels);

  int get fgRgb => (channels >> 32) & 0x00ffffff;
  int get bgRgb => channels & 0x00ffffff;
  int get fgFlags => (channels >> 56) & 0xff;
  int get bgFlags => (channels >> 24) & 0xff;
}

class _TestResult {
  final String label;
  final String input;
  final int putReturnCode;
  final List<_CellSnapshot> cells;
  _TestResult(this.label, this.input, this.putReturnCode, this.cells);
}

Future<int> main() async {
  // Probe before touching the terminal so a missing library exits cleanly.
  try {
    nc.NotCurses(nc.CursesOptions(loglevel: nc.LogLevel.silent)).stop();
  } catch (e) {
    stderr.writeln('libnotcurses not available: $e');
    stderr.writeln('Install notcurses and retry.');
    return 1;
  }

  final results = <_TestResult>[];
  nc.NotCurses? notcurses;

  try {
    notcurses = nc.NotCurses(nc.CursesOptions(loglevel: nc.LogLevel.silent));
    if (notcurses.notInitialized) {
      stderr.writeln('Failed to initialize notcurses.');
      return 1;
    }
    final plane = notcurses.stdplane();
    final cols = plane.dimx();

    List<_CellSnapshot> readCells(int row, int startCol, int len) {
      final out = <_CellSnapshot>[];
      for (var i = 0; i < len; i++) {
        final c = startCol + i;
        if (c >= cols) break;
        final data = plane.atYX(row, c);
        if (data == null) {
          out.add(_CellSnapshot(row, c, '<null>', 0, 0));
        } else {
          out.add(_CellSnapshot(
              row, c, data.egc, data.stylemask, data.channels));
        }
      }
      return out;
    }

    // Headers
    plane.putStrYX(0, 0,
        'Notcurses SGR pass-through check — press any key to stop and see results');

    // --- A: plain text ---
    plane.putStrYX(2, 0, 'A: plain text "hello"');
    final aRc = plane.putStrYX(3, 2, _plainText);
    results.add(_TestResult('A: plain text', _plainText, aRc,
        readCells(3, 2, _plainText.length)));

    // --- B: text with embedded SGR ---
    plane.putStrYX(5, 0, 'B: "\\x1b[31mhello\\x1b[0m" via putStrYX');
    final bRc = plane.putStrYX(6, 2, _sgrText);
    // Read 18 cells (more than the input is long) to see how many notcurses
    // touched and what landed in them.
    results.add(
        _TestResult('B: embedded SGR', _sgrText, bRc, readCells(6, 2, 18)));

    // --- C: setFgRGB + plain text (control: the "correct" way) ---
    plane.putStrYX(8, 0, 'C: setFgRGB(0xff0000) + "hello"');
    plane.setFgRGB(_redRgb);
    final cRc = plane.putStrYX(9, 2, _plainText);
    plane.setFgDefault();
    results.add(_TestResult('C: setFgRGB+text', _plainText, cRc,
        readCells(9, 2, _plainText.length)));

    notcurses.render();

    // Block for any key so the user can observe rendering before teardown.
    notcurses.getBlocking();
  } finally {
    notcurses?.stop();
  }

  // Terminal is restored — safe to print to stdout.
  _printReport(results);

  return 0;
}

void _printReport(List<_TestResult> results) {
  stdout.writeln('');
  stdout.writeln('=' * 72);
  stdout.writeln('Notcurses SGR pass-through verification');
  stdout.writeln('=' * 72);
  stdout.writeln('');
  for (final r in results) {
    stdout.writeln('${r.label}');
    stdout.writeln(
        '  input          : ${_quote(r.input)}  (${r.input.length} bytes)');
    stdout.writeln('  putStrYX rc    : ${r.putReturnCode}');
    stdout.writeln('  cells written  : ${_describeCells(r.cells)}');
    stdout.writeln('  per-cell dump:');
    for (final c in r.cells) {
      if (c.egc.isEmpty) {
        stdout.writeln('    [${c.row},${c.col}] egc=<empty>'
            '  style=0x${c.stylemask.toRadixString(16)}'
            '  fg=${_rgbHex(c.fgRgb)}  bg=${_rgbHex(c.bgRgb)}');
        continue;
      }
      stdout.writeln('    [${c.row},${c.col}] egc=${_quote(c.egc).padRight(8)}'
          '  style=0x${c.stylemask.toRadixString(16)}'
          '  fg=${_rgbHex(c.fgRgb)}  bg=${_rgbHex(c.bgRgb)}');
    }
    stdout.writeln('');
  }

  // Heuristic verdict — based on test B's results.
  stdout.writeln('Verdict:');
  final b = results.firstWhere((r) => r.label.startsWith('B'));
  final hasEscapeCell =
      b.cells.any((c) => c.egc.codeUnits.contains(0x1b));
  final firstFiveAreHello = b.cells.length >= 5 &&
      b.cells.take(5).map((c) => c.egc).join() == 'hello';
  final firstFiveAreRed = b.cells.take(5).every((c) => c.fgRgb == _redRgb);

  if (b.putReturnCode <= 0) {
    stdout.writeln(
        '  ❌ putStrYX rejected embedded SGR (returned ${b.putReturnCode}).');
    stdout.writeln(
        '     Fix: parse SGR out in tina_console; call setFgRGB/setStyles.');
  } else if (firstFiveAreHello && firstFiveAreRed) {
    stdout.writeln(
        '  ✅ Notcurses interprets embedded SGR — current tina code is OK.');
  } else if (firstFiveAreHello && !firstFiveAreRed) {
    stdout.writeln('  ⚠️  Notcurses STRIPPED the SGR but kept "hello" plain.');
    stdout.writeln(
        '     Colours lost. Fix: translate SGR via setFgRGB before putStrYX.');
  } else if (hasEscapeCell) {
    stdout.writeln(
        '  ❌ Notcurses wrote the escape bytes as literal cell glyphs.');
    stdout.writeln(
        '     Fix mandatory: parse SGR in tina_console; never pass escapes.');
  } else {
    stdout.writeln(
        '  ❓ Unexpected cell pattern — inspect the per-cell dump above.');
  }
  stdout.writeln('');
  stdout.writeln('Reference:');
  stdout.writeln('  A is the "plain text" baseline.');
  stdout.writeln(
      '  C is the "correct" way — setFgRGB then plain text. fg should be 0xff0000.');
}

String _describeCells(List<_CellSnapshot> cells) {
  final nonEmpty = cells.where((c) => c.egc.isNotEmpty).length;
  return '$nonEmpty non-empty of ${cells.length} sampled';
}

String _rgbHex(int v) => '0x${v.toRadixString(16).padLeft(6, '0')}';

String _quote(String s) {
  final buf = StringBuffer('"');
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x1b) {
      buf.write(r'\x1b');
    } else if (c < 0x20 || c == 0x7f) {
      buf.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
    } else if (c == 0x22) {
      buf.write(r'\"');
    } else if (c == 0x5c) {
      buf.write(r'\\');
    } else {
      buf.writeCharCode(c);
    }
  }
  buf.write('"');
  return buf.toString();
}
