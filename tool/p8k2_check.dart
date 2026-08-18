/// tin-p8k2 deterministic oracle: replay a captured notcurses byte stream
/// (tmux pipe-pane capture of a tool/p8k2_repro.dart run) through the
/// test-suite VirtualTerminal — which models tmux-class glyph widths and
/// deferred autowrap, the layout notcurses' raster does NOT model — and
/// assert every content row kept its panel borders.
///
/// This is the raster-level regression test the ticket asks for: a recording
/// fake can't catch it (the defect is in what the raster emits, not in what
/// we hand it), and the live 1-in-3 tmux repro is timing luck. Feeding the
/// real raster's bytes to a tmux-class emulator makes the spill — the erase
/// run wrapping onto the next row over the left border — deterministic.
///
/// Usage: dart run tool/p8k2_check.dart <raw.log> <cols> <rows>
/// Exit 0 = all borders intact; exit 1 = borderless rows (printed).
library;

import 'dart:io';

import '../packages/tina_console/test/virtual_terminal.dart';

void main(List<String> argv) {
  if (argv.length < 3) {
    stderr.writeln('usage: p8k2_check.dart <raw.log> <cols> <rows>');
    exit(2);
  }
  final path = argv[0];
  final cols = int.parse(argv[1]);
  final rows = int.parse(argv[2]);
  final raw = File(path).readAsStringSync();
  // Cut the stream at the repro's completion sentinel: everything after it
  // (leaveAltScreen teardown, the shell prompt resuming) is not part of the
  // frame under test.
  final end = raw.indexOf('P8K2-REPRO-COMPLETE');
  final stream = end < 0 ? raw : raw.substring(0, end);

  // Strip sequences the VirtualTerminal doesn't model but nc emits during
  // init/teardown: OSC (palette/default-bg queries) and DCS replies would
  // otherwise be laid out as printable text.
  final cleaned = stream
      .replaceAll(RegExp('\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)'), '')
      .replaceAll(RegExp('\x1bP[^\x1b]*\x1b\\\\'), '');

  final vt = VirtualTerminal(width: cols, height: rows);
  vt.feed(cleaned);

  // Content rows are everything between the top and bottom frame rows.
  var bad = 0;
  for (var r = 1; r < rows - 1; r++) {
    final left = vt.charAt(r, 0);
    final right = vt.charAt(r, cols - 1);
    final lOk = left == '│';
    final rOk = right == '│';
    if (!lOk || !rOk) {
      bad++;
      final row = vt.rowText(r);
      stdout.writeln(
          'row ${r.toString().padLeft(2)}: left=${left == '' ? '(cont)' : left} '
          'right=$right :: ${row.substring(0, cols > 60 ? 60 : cols)}');
    }
  }
  stdout.writeln(bad == 0
      ? 'p8k2: all ${rows - 2} content rows keep both borders'
      : 'p8k2: $bad borderless row(s)');
  exit(bad == 0 ? 0 : 1);
}
