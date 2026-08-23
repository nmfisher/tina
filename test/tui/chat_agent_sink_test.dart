import 'package:tina/chat_agent_sink.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

Screen _screen() => Screen(
    io: FakeStdio()..columns = 120, layout: ScreenLayout.fromSize(120, 24));

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
