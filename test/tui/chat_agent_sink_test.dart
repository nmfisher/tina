import 'package:tina/chat_agent_sink.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// Wide enough (chat box ≈ 65% of width) that every row under test stays on
/// a single painted line, so assertions can treat rows as unbroken strings.
Screen _screen({int width = 400}) => Screen(
    io: FakeStdio()..columns = width, layout: ScreenLayout.fromSize(width, 24));

/// The region's painted rows, joined — what the user would see in the chat.
String _painted(ScrollingTextRegion chat) {
  final buf = StringBuffer();
  for (var i = 0; i < 40; i++) {
    final t = chat.debugPaintedText(i);
    if (t == null) break;
    buf.writeln(t.trimRight());
  }
  return buf.toString();
}

/// Pins the streamed-output cap in [ChatAgentSink]: short streams print
/// fully; long streams are capped for display, buffered in full, and handed
/// to `onCapped` for the `/output` viewer.
void main() {
  test('a short stream prints fully and is never capped', () {
    final chat = ScrollingTextRegion(_screen());
    final capped = <CappedToolOutput>[];
    final sink = ChatAgentSink(chat, Spinner(enabled: false),
        onCapped: capped.add);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'echo hi'}));
    sink.toolOutput(const ToolOutputEvent('bash', 't1', 'line one\n'));
    sink.toolOutput(const ToolOutputEvent('bash', 't1', 'line two\n'));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    final painted = _painted(chat);
    expect(painted, contains('→ bash: echo hi'));
    expect(painted, contains('line one'));
    expect(painted, contains('line two'));
    expect(painted, contains('  ok'));
    expect(painted, isNot(contains('/output')));
    expect(capped, isEmpty);
  });

  test('a long stream is capped for display but preserved for /output',
      () {
    final chat = ScrollingTextRegion(_screen());
    final capped = <CappedToolOutput>[];
    final sink = ChatAgentSink(chat, Spinner(enabled: false),
        onCapped: capped.add);
    final long = 'x' * 700;

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'find .'}));
    sink.toolOutput(ToolOutputEvent('bash', 't1', long));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    final painted = _painted(chat);
    // The visible stream stops at the cap, with a pointer to the viewer.
    expect(painted, contains('more chars'));
    expect(painted, contains('/output'));
    expect(painted, contains('  ok'));
    expect(painted.length, lessThan(900));
    // The full output is preserved for the viewer.
    expect(capped.single.toolName, 'bash');
    expect(capped.single.text, long);
    expect(capped.single.hiddenChars, 100);
  });

  test('a crossing chunk is split at the cap, not dropped', () {
    final chat = ScrollingTextRegion(_screen());
    final capped = <CappedToolOutput>[];
    final sink = ChatAgentSink(chat, Spinner(enabled: false),
        onCapped: capped.add);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolOutput(ToolOutputEvent('bash', 't1', 'a' * 400));
    sink.toolOutput(ToolOutputEvent('bash', 't1', 'b' * 400));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    final painted = _painted(chat);
    // The part of the second chunk that fits under the cap was printed (rows
    // wrap at the panel width, so compare the flattened text).
    final flat = painted.replaceAll('\n', '');
    expect(flat, contains('b' * 200));
    expect(flat, isNot(contains('b' * 201)));
    expect(capped.single.text, '${'a' * 400}${'b' * 400}');
    expect(capped.single.hiddenChars, 200);
  });

  test('stderr after the cap is buffered, not printed', () {
    final chat = ScrollingTextRegion(_screen());
    final capped = <CappedToolOutput>[];
    final sink = ChatAgentSink(chat, Spinner(enabled: false),
        onCapped: capped.add);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolOutput(ToolOutputEvent('bash', 't1', 'x' * 700));
    sink.toolOutput(
        const ToolOutputEvent('bash', 't1', 'stderr tail', stderr: true));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    expect(_painted(chat), isNot(contains('stderr tail')));
    expect(capped.single.text, contains('stderr tail'));
  });

  test('an error result still shows failed alongside the cap note', () {
    final chat = ScrollingTextRegion(_screen());
    final capped = <CappedToolOutput>[];
    final sink = ChatAgentSink(chat, Spinner(enabled: false),
        onCapped: capped.add);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolOutput(ToolOutputEvent('bash', 't1', 'x' * 700));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1',
        isError: true, result: 'boom'));

    final painted = _painted(chat);
    expect(painted, contains('failed: boom'));
    expect(painted, contains('/output'));
    expect(capped.single.hiddenChars, 100);
  });

  // --- #49: tool-row head+tail truncation ---

  test('a long bash command keeps its tail, not just its head', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false));
    // 84 chars: the `| sh` at the tail is what an approver needs to see.
    final cmd = 'a' * 80 + '| sh';

    sink.toolStart(ToolStartEvent('bash', 't1', {'command': cmd}));

    final painted = _painted(chat);
    // Head: 52 chars of the command. Ellipsis. Tail: the last 27, which ends
    // in `| sh`.
    final row =
        painted.split('\n').firstWhere((l) => l.contains('→ bash:'));
    expect(row, contains('a' * 52));
    expect(row, contains('…'));
    expect(row, endsWith('a' * 23 + '| sh'));
    // And the middle of the command is dropped: the longest surviving run of
    // `a`s is the 52-char head, so no 53-run can survive.
    expect(row, isNot(contains('a' * 53)));
  });

  test('a short bash command renders verbatim', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false));

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'echo hi'}));

    final row =
        _painted(chat).split('\n').firstWhere((l) => l.contains('→ bash:'));
    expect(row.trim(), '→ bash: echo hi');
  });

  test('an 80-char bash command renders verbatim (the budget boundary)', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false));
    final cmd = 'b' * 80;

    sink.toolStart(ToolStartEvent('bash', 't1', {'command': cmd}));

    final row =
        _painted(chat).split('\n').firstWhere((l) => l.contains('→ bash:'));
    // At exactly the 80-char budget the command is verbatim: no ellipsis.
    expect(row, contains('→ bash: $cmd'));
    expect(row, isNot(contains('…')));
  });

  test('a long k=v summary keeps both its head and its tail', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false));
    // 5 + 4 + 90 + 4 = 103 chars under the 80-char budget.
    final value = 'HEAD' + 'x' * 90 + 'TAIL';

    sink.toolStart(
        ToolStartEvent('mytool', 't1', {'text': value}));

    final row =
        _painted(chat).split('\n').firstWhere((l) => l.contains('→ mytool:'));
    expect(row, contains('mytool: text=HEAD')); // head survives
    expect(row, contains('…'));
    expect(row, endsWith('x' * 23 + 'TAIL')); // tail survives
    // Middle dropped: the value has a 90-run of `x`s; the head keeps only its
    // first 48, the tail its last 23. So no 49-run can survive — the middle
    // of the run is what truncation cut.
    expect(row, isNot(contains('x' * 49)));
  });

  // --- #50: failed tool results reach the /output ring when cut ---

  test(
      'a failed call with a long result and no stream caps the line but '
      'keeps the full error for /output', () {
    final chat = ScrollingTextRegion(_screen());
    final capped = <CappedToolOutput>[];
    final sink = ChatAgentSink(chat, Spinner(enabled: false),
        onCapped: capped.add);
    final result = 'E' * 250 + 'THE REAL ERROR TAIL';

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolComplete(ToolCompleteEvent('bash', 't1',
        isError: true, result: result));

    final painted = _painted(chat);
    // (1) The truncated failed line.
    expect(painted, contains('failed: ${'E' * 200}…'));
    expect(painted, isNot(contains('THE REAL ERROR TAIL')));
    // (2) A pointer to the viewer, mirroring the capped-output voice.
    expect(painted, contains('… (/output for the full error)'));
    // (3) A ring entry carrying the FULL result.
    expect(capped, hasLength(1));
    expect(capped.single.text, result);
    expect(capped.single.text, contains('THE REAL ERROR TAIL'));
    expect(capped.single.hiddenChars, 69); // 269 - 200 printed chars
    expect(capped.single.toolName, 'bash');
    expect(capped.single.input, {'command': 'go'});
  });

  test('a failed call with a short result stays as before', () {
    final chat = ScrollingTextRegion(_screen());
    final capped = <CappedToolOutput>[];
    final sink = ChatAgentSink(chat, Spinner(enabled: false),
        onCapped: capped.add);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1',
        isError: true, result: 'boom'));

    final painted = _painted(chat);
    expect(painted, contains('failed: boom'));
    expect(painted, isNot(contains('/output for the full error')));
    expect(capped, isEmpty);
  });

  test('a successful call behaves exactly as before', () {
    final chat = ScrollingTextRegion(_screen());
    final capped = <CappedToolOutput>[];
    final sink = ChatAgentSink(chat, Spinner(enabled: false),
        onCapped: capped.add);
    final result = 'r' * 500; // far past 200 chars — still no failure path

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolComplete(ToolCompleteEvent('bash', 't1',
        isError: false, result: result));

    final painted = _painted(chat);
    expect(painted, contains('  ok'));
    expect(painted, isNot(contains('/output')));
    expect(capped, isEmpty);
  });

  test('a notice over an unterminated stream starts its own row', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false));

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    // The stream ends mid-row (no trailing newline) and the notice lands
    // before the tool completes.
    sink.toolOutput(const ToolOutputEvent('bash', 't1', 'partial row'));
    sink.notice('[watchdog] turn idle for 5m');

    final painted = _painted(chat);
    // Without ensureNewline the notice glues onto the partial row.
    expect(painted, isNot(contains('partial row[watchdog] turn idle for 5m')));
    final lines = painted.split('\n');
    final noticeRow =
        lines.where((l) => l.contains('[watchdog] turn idle for 5m')).toList();
    expect(noticeRow, hasLength(1));
    expect(noticeRow.single.trimLeft(), '[watchdog] turn idle for 5m');
  });
}
