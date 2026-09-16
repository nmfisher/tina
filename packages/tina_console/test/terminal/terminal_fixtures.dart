/// Table-driven fixture harness for the terminal emulator (tin-t8wd).
///
/// Doctrine (plan Phase 1 acceptance): hand-written expected grids are the
/// oracle; the production parser never asserts its own output (and
/// test/virtual_terminal.dart stays a rendering harness, never promoted).
/// Every fixture is replayed three ways:
///
///   1. whole   — the entire byte string as one `feed` call,
///   2. bytewise — one byte per `feed` call,
///   3. splits  — every possible split point, one at a time (a sequence is
///      split exactly once at position k; both halves are single feeds).
///
/// Splits are where persistent-state-machine bugs hide: a CSI or OSC cut in
/// half, a UTF-8 lead without its continuation, an ESC+\ terminator
/// straddling a chunk boundary.
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_console/src/terminal/terminal_emulator.dart';

/// Expected screen content as text: `#` = blank, other chars = themselves.
/// Rows are top-to-bottom and must match the emulator size exactly.
/// For wide-glyph fixtures use `.` in the trailing half's position.
typedef Grid = List<String>;

class Fixture {
  Fixture({
    required this.name,
    required this.bytes,
    this.rows = 4,
    this.cols = 8,
    Grid? expectGrid,
    this.cursorRow = 0,
    this.cursorCol = 0,
    this.pendingWrap = false,
    this.scrollbackRows = 0,
    this.replies = const <int>[],
    this.events = const <TerminalEvent>[],
    this.state,
  })  : expectGrid = expectGrid ?? const <String>[] {
    assert(
      this.expectGrid.isEmpty || this.expectGrid.length == rows,
      'oracle row count must match fixture rows',
    );
  }

  final String name;
  final List<int> bytes;
  final int rows;
  final int cols;
  final Grid expectGrid;
  final int cursorRow;
  final int cursorCol;
  final bool pendingWrap;
  final int scrollbackRows;
  final List<int> replies;
  final List<TerminalEvent> events;

  /// Extra assertions on the emulator after the replay.
  final void Function(TerminalEmulator emulator)? state;
}

const String blank = '#';

/// Encodes a Dart string literal (with \x1B escapes) to bytes.
List<int> esc(String s) => utf8.encode(s);

/// Renders the active screen rows as fixture-style text.
Grid renderGrid(TerminalEmulator t) {
  final snap = t.snapshot();
  return [
    for (final row in snap.screen)
      [
        for (final cell in row.cells)
          if (cell.isContinuation)
            '.' // second half of a wide glyph
          else if (cell.text.isEmpty)
            blank
          else
            cell.cluster,
      ].join(),
  ];
}

void _expect(Fixture f, TerminalEmulator t) {
  if (f.expectGrid.isNotEmpty) {
    expect(renderGrid(t), f.expectGrid, reason: f.name);
  }
  expect(t.snapshot().cursorRow, f.cursorRow, reason: '${f.name} cursorRow');
  expect(t.snapshot().cursorCol, f.cursorCol, reason: '${f.name} cursorCol');
  expect(t.snapshot().pendingWrap, f.pendingWrap,
      reason: '${f.name} pendingWrap');
  expect(t.primary.scrollback.length, f.scrollbackRows,
      reason: '${f.name} scrollback');
  final snapped = t.snapshot();
  expect(snapped.primaryActive || t.inAlternateScreen, isTrue);
}

/// Registers the three replays for [f]. Call inside a [group].
void replayAll(Fixture f) {
  test('${f.name} [whole]', () {
    final t = TerminalEmulator(initialRows: f.rows, initialCols: f.cols);
    final result = t.feed(f.bytes);
    _expect(f, t);
    expect(result.replies, f.replies, reason: '${f.name} replies');
    expect(result.events, f.events, reason: '${f.name} events');
    f.state?.call(t);
  });

  test('${f.name} [byte-by-byte]', () {
    final t = TerminalEmulator(initialRows: f.rows, initialCols: f.cols);
    List<int> replies = const <int>[];
    final events = <TerminalEvent>[];
    for (final byte in f.bytes) {
      final result = t.feed([byte]);
      replies = [...replies, ...result.replies];
      events.addAll(result.events);
    }
    _expect(f, t);
    expect(replies, f.replies, reason: '${f.name} replies');
    expect(events, f.events, reason: '${f.name} events');
    f.state?.call(t);
  });

  test('${f.name} [every split]', () {
    if (f.bytes.length < 2) {
      return; // nothing to split
    }
    for (var cut = 1; cut < f.bytes.length; cut++) {
      final t = TerminalEmulator(initialRows: f.rows, initialCols: f.cols);
      final first = t.feed(f.bytes.sublist(0, cut));
      final second = t.feed(f.bytes.sublist(cut));
      final replies = [...first.replies, ...second.replies];
      final events = [...first.events, ...second.events];
      try {
        _expect(f, t);
        expect(replies, f.replies, reason: '${f.name} replies');
        expect(events, f.events, reason: '${f.name} events');
        f.state?.call(t);
      } on TestFailure {
        fail('${f.name} failed split at byte $cut');
      }
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}

/// Registers a plain (non-replayed) assertion block.
void emulatorCase(String name, void Function(TerminalEmulator t) body,
    {int rows = 4, int cols = 8}) {
  test(name, () {
    final t = TerminalEmulator(initialRows: rows, initialCols: cols);
    body(t);
  });
}

/// Renders the active screen as fixture-style text (`#` blank, `.` cont).
Grid renderGridOf(TerminalEmulator t) => renderGrid(t);
