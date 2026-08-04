// Headless input-latency benchmark for tina_console.
//
// Drives LineEditor + AnsiInputBackend + AnsiBackend against an in-memory
// recording Stdio, feeds deterministic input workloads, and prints a
// machine-readable JSON report (per-kind, per-stage p50/p95/p99 + counters).
//
// Enable tracing so the recorder collects samples:
//   COCOON_DEBUG_INPUT_LATENCY=1 dart run tool/latency_bench.dart \
//     --workload typing-idle --events 1000
//
// The `counters` object includes the Phase 4 styled-run fields: `styleChanges`
// (SGR sequences seen), `styledRunEmits` (cached/collapsed run lists emitted),
// and `styleParseHits` / `styleParseMisses` (parse-cache hit/miss). A
// `styled-comet` workload paints a heavy styled rail repeatedly to exercise
// that layer. Counters are zero under the headless ANSI backend (ANSI writes raw
// SGR with no per-cell setter state); the flatten + parse-cache win shows on a
// live notcurses run and is asserted by test/styled_runs_test.dart.
//
// Live (notcurses) mode is a placeholder that reports `{"skipped": true}`
// until a real TTY/libnotcurses driver is wired — it never passes as a false
// functional success.
//
// Modelled on bin/check_notcurses_sgr.dart (probe-then-skip) and the
// line_editor_test.dart _editor() wiring + _flush() microtask drain.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/input_latency.dart';

/// Minimal in-memory [Stdio]: captures written output and lets the harness
/// inject input bytes. Mirrors test/stdio_fake.dart without taking a test dep.
class _RecordingStdio implements Stdio {
  final _controller = StreamController<List<int>>(sync: true);
  final StringBuffer written = StringBuffer();
  int columns;
  final bool hasTerminalValue;

  _RecordingStdio({this.columns = 80, this.hasTerminalValue = true});

  void feedBytes(List<int> bytes) => _controller.add(bytes);

  @override
  Stream<List<int>> get stdin => _controller.stream;

  @override
  void write(String s) => written.write(s);

  @override
  int get terminalColumns => columns;

  @override
  bool get hasTerminal => hasTerminalValue;

  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();

  void close() => _controller.close();
}

const _workloads = [
  'typing-idle',
  'typing-while-1-stream',
  'typing-while-3-stream',
  'paste-10k',
  'wrap-no-scroll',
  'scroll-24',
  'scroll-60',
  'scroll-120',
  'sustained-scroll',
  'styled-comet',
  'styled-progress',
  'focus-cycle',
  'resize-during-stream',
];

Future<int> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('workload', abbr: 'w', defaultsTo: 'typing-idle')
    ..addOption('backend', abbr: 'b', defaultsTo: 'ansi')
    ..addOption('events', abbr: 'n', defaultsTo: '1000')
    ..addOption('height', defaultsTo: '24')
    ..addOption('out', abbr: 'o')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');
  final args = parser.parse(argv);
  if (args['help'] as bool) {
    stderr.writeln('Usage: dart run tool/latency_bench.dart --workload <id> '
        '[--backend ansi|live] [--events N] [--height H] [--out file.json]');
    stderr.writeln('Workloads: ${_workloads.join(', ')}');
    return 0;
  }
  final workload = args['workload'] as String;
  final backend = args['backend'] as String;
  final events = int.parse(args['events'] as String);
  final height = int.parse(args['height'] as String);
  final out = args['out'] as String?;

  if (!_workloads.contains(workload)) {
    stderr.writeln('Unknown workload: $workload. Choose: ${_workloads.join(', ')}');
    return 2;
  }

  // Tracing must be on for the recorder to collect samples. Force-enable so
  // the harness works without the env var too.
  if (!InputLatency.enabled) InputLatency.forceEnable();
  InputLatency.reset();

  final env = <String, dynamic>{
    'workload': workload,
    'backend': backend,
    'events': events,
    'height': height,
  };

  Map<String, dynamic> result;
  if (backend == 'live') {
    result = _runLive(workload, events, height, env);
  } else {
    result = await _runHeadless(workload, events, height, env);
  }

  final json = const JsonEncoder.withIndent('  ').convert(result);
  if (out != null) {
    File(out).writeAsStringSync('$json\n');
    stderr.writeln('Wrote $out');
  } else {
    stdout.writeln(json);
  }
  return 0;
}

Future<Map<String, dynamic>> _runHeadless(
  String workload,
  int events,
  int height,
  Map<String, dynamic> env,
) async {
  final io = _RecordingStdio(columns: 80, hasTerminalValue: true);
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, height),
    ansi: AnsiCapable.yes,
  );
  final editor = LineEditor(
    screen: screen,
    escapeTimeout: Duration.zero,
  );

  switch (workload) {
    case 'typing-idle':
      await _feedChars(io, editor, events);
    case 'paste-10k':
      await _feedPaste(io, editor, 10000);
    case 'wrap-no-scroll':
      await _feedWrapNoScroll(io, editor, events);
    case 'typing-while-1-stream':
      await _feedTypingWhileStream(io, editor, events, 1);
    case 'typing-while-3-stream':
      await _feedTypingWhileStream(io, editor, events, 3);
    case 'focus-cycle':
      await _feedFocusCycle(io, editor, events);
    case 'resize-during-stream':
      await _feedResizeDuringStream(io, screen, editor, events);
    case 'scroll-24':
    case 'scroll-60':
    case 'scroll-120':
      await _feedScroll(io, editor, events);
    case 'sustained-scroll':
      await _feedSustainedScroll(io, screen, editor, events);
    case 'styled-comet':
      await _feedStyledComet(io, screen, events);
    case 'styled-progress':
      await _feedStyledProgress(io, screen, events);
    default:
      stderr.writeln('workload $workload not implemented in headless mode');
  }

  editor.close();
  io.close();
  final report = InputLatency.report();
  return {
    ...env,
    'mode': 'headless-ansi',
    'latency': report.kinds,
    'counters': report.counters,
  };
}

Map<String, dynamic> _runLive(
  String workload,
  int events,
  int height,
  Map<String, dynamic> env,
) {
  // Live mode needs libnotcurses + a controlling TTY; not available in CI or
  // most dev shells. Report skipped so a missing env is never a false pass.
  return {
    ...env,
    'mode': 'live-notcurses',
    'skipped': true,
    'reason': 'live notcurses benchmark not implemented in this harness; '
        'run headless ansi mode for regression numbers',
  };
}

Future<void> _feedChars(_RecordingStdio io, LineEditor editor, int n) async {
  // 'a' * n, then Enter. Each byte drives parse -> event -> _onEvent -> redraw
  // -> flush, exercising the full staged-trace path.
  editor.readLine('> ');
  for (var i = 0; i < n; i++) {
    io.feedBytes([0x61]); // 'a'
    await _flush();
  }
  io.feedBytes([0x0d]); // Enter
  await _flush();
}

Future<void> _feedPaste(_RecordingStdio io, LineEditor editor, int n) async {
  editor.readLine('> ');
  // Bracketed paste: ESC[200~ <bytes> ESC[201~
  final bytes = <int>[
    0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e, // ESC[200~
    ...List<int>.filled(n, 0x61), // 'a' * n
    0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e, // ESC[201~
  ];
  io.feedBytes(bytes);
  await _flush();
  io.feedBytes([0x0d]); // Enter
  await _flush();
}

Future<void> _feedWrapNoScroll(_RecordingStdio io, LineEditor editor, int n) async {
  // Type enough chars to wrap a line but not fill the height (no scroll).
  editor.readLine('> ');
  for (var i = 0; i < n; i++) {
    io.feedBytes([0x61]);
    await _flush();
  }
  io.feedBytes([0x0d]);
  await _flush();
}

Future<void> _feedTypingWhileStream(
  _RecordingStdio io,
  LineEditor editor,
  int n,
  int streamCount,
) async {
  editor.readLine('> ');
  for (var i = 0; i < n; i++) {
    // Interleave chat-region appends between keystrokes to simulate
    // background streaming contention.
    if (i % 50 == 0) {
      for (var s = 0; s < streamCount; s++) {
        editor.screen.chat.writeln('stream $s tick $i');
      }
      await _flush();
    }
    io.feedBytes([0x61]);
    await _flush();
  }
  io.feedBytes([0x0d]);
  await _flush();
}

// Sustained-streaming workload: stream whole lines fast enough that chat
// scrolls on every append. Phase 3 collapses those scrolls into native
// BackendSurface.scrollRows calls, so the backend write count scales with the
// number of new lines rather than events x height. Headless ANSI still does
// the O(H) _redrawAll (scrollRows is false there); the notcurses win is
// asserted by test/chat_native_scroll_test.dart and observable in a live run.
Future<void> _feedSustainedScroll(
  _RecordingStdio io,
  Screen screen,
  LineEditor editor,
  int n,
) async {
  for (var i = 0; i < n; i++) {
    screen.chat.writeln('stream-${i.toString().padLeft(5, '0')}-'
        'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx');
    await _flush();
  }
}

// Phase 4 — styled-comet. Paints a heavy styled rail (a comet-like bar that
// fills the terminal width with many adjacent truecolor SGR runs) repeatedly.
// Consecutive runs reuse the same color, so the parse cache collapses them:
// N setter calls + reset become far fewer (proven by test/styled_runs_test.dart
// T-07). The rail is written as identical rows, so a notcurses backend parses
// the string once (one miss) and hits the cache on every subsequent emit.
//
// The headless ANSI path writes raw SGR bytes and never parses, so the
// parse/cache counters (styleChanges, styledRunEmits, styleParseHits/Misses)
// are correctly zero there — ANSI has no per-cell setter state to minimize and
// doesn't need the parse layer. Those counters populate, and the flatten, only
// on a notcurses backend (live mode) and in the recording-fake unit tests, so
// the win is observable in a live run and asserted by the fakes — exactly the
// same layering Phase 3 used for native scroll (tool bench + fake unit test).
Future<void> _feedStyledComet(
  _RecordingStdio io,
  Screen screen,
  int n,
) async {
  final rail = _heavyStyledRail(io.terminalColumns);
  for (var i = 0; i < n; i++) {
    screen.chat.writeln(rail);
    await _flush();
  }
}

/// A heavy styled rail filling [width] columns with adjacent truecolor SGR
/// runs. Every [runSegments] consecutive runs share a color so the parse cache
// collapses them into a single setter group + putStr (instead of one per run).
// Ends in a reset so the row lands on a known default baseline.
String _heavyStyledRail(int width) {
  const seg = 2; // chars per run
  const runSegments = 4; // consecutive same-color runs collapse to one
  const colors = [
    '38;2;30;110;130', // rail cyan
    '1;38;2;175;255;255', // bright head cyan (bold)
    '38;2;60;150;170', // tail fade
  ];
  final sb = StringBuffer();
  var segIdx = 0;
  for (var c = 0; c + seg <= width; c += seg) {
    final color = colors[((segIdx ~/ runSegments) % colors.length)];
    sb.write('\x1b[${color}m');
    sb.write('#' * seg);
    segIdx++;
  }
  sb.write('\x1b[0m');
  return sb.toString();
}

// Phase 4 follow-on — styled-progress. Paints a multi-SGR progress bar whose
// colored tail grows one segment per event, re-emitting the SAME visual row
// each time (no newline). Each repaint changes only the tail, so the surface
// path partial-patches the changed run span instead of a full-row rewrite. The
// win vs a full rewrite shows up as far fewer erasedCells/gridWrites per event
// (only the tail span is erased + written, not the whole width). Headless ANSI
// exercises the surface path (AnsiBackendSurface); the notcurses win is the same
// partial-patch on a live child plane.
Future<void> _feedStyledProgress(
  _RecordingStdio io,
  Screen screen,
  int n,
) async {
  // Head: a fixed green label that stays unchanged across repaints.
  screen.chat.write('\x1b[32mPROGRESS\x1b[0m ');
  await _flush();
  const seg = 4; // chars added to the colored tail per event
  const color = '38;2;30;110;130'; // rail cyan
  for (var i = 0; i < n; i++) {
    // Append to the current row (no newline) so the row is re-emitted with the
    // same head and a longer cyan tail → partial patch of the changed span.
    screen.chat.write('\x1b[${color}m${'█' * seg}\x1b[0m');
    await _flush();
  }
}

Future<void> _feedFocusCycle(_RecordingStdio io, LineEditor editor, int n) async {
  editor.readLine('> ');
  for (var i = 0; i < n; i++) {
    io.feedBytes([0x1b, 0x5b, 0x44]); // ESC [ D  (left arrow)
    await _flush();
  }
  io.feedBytes([0x0d]);
  await _flush();
}

Future<void> _feedScroll(_RecordingStdio io, LineEditor editor, int n) async {
  // Append n chat lines to drive the scroll path at the harness height.
  for (var i = 0; i < n; i++) {
    editor.screen.chat.writeln('line $i');
    await _flush();
  }
}

Future<void> _feedResizeDuringStream(
  _RecordingStdio io,
  Screen screen,
  LineEditor editor,
  int n,
) async {
  editor.readLine('> ');
  for (var i = 0; i < n; i++) {
    if (i % 100 == 0) {
      screen.resize(ScreenLayout.fromSize(80, 24 + (i ~/ 100) % 3));
    }
    editor.screen.chat.writeln('stream tick $i');
    io.feedBytes([0x61]);
    await _flush();
  }
  io.feedBytes([0x0d]);
  await _flush();
}

/// Drain pending microtasks so deferred input events (the backend schedules
/// all-but-first per chunk via scheduleMicrotask) are delivered. Mirrors
/// line_editor_test.dart's _flush().
Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}
