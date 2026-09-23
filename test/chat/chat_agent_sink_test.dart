import 'package:tina/chat/chat_agent_sink.dart';
import 'package:tina/chat/chat_transcript.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// Wide enough (chat box ≈ 65% of width) that every row under test stays on
/// a single painted line, so assertions can treat rows as unbroken strings.
Screen _screen({int width = 400}) => Screen(
    io: FakeStdio()..columns = width, layout: ScreenLayout.fromSize(width, 24));

/// The transcript's tool-call blocks, in order. The sink also writes notices
/// (the fold hint), so a test that means "the call" has to say so.
List<ChatBlock> _calls(ChatAgentSink sink) =>
    sink.blocks.where((b) => b.kind == ChatBlockKind.toolCall).toList();

/// The text a folded block reveals, whole: the last tool call by default.
String _bodyOf(ChatAgentSink sink, [int? index]) {
  final block = index == null ? _calls(sink).last : sink.blocks[index];
  return block.body.map((l) => l.runs.map((r) => r.text).join()).join('\n');
}

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

/// Pins where a tool call's output lives: in the block behind its header, which
/// is the only place it now lives — the `/output` ring is gone, and the block's
/// fold is how a reader gets at it.
void main() {
  test('a call is one header row; its output is kept behind it', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'echo hi'}));
    sink.toolOutput(const ToolOutputEvent('bash', 't1', 'line one\n'));
    sink.toolOutput(const ToolOutputEvent('bash', 't1', 'line two\n'));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    final painted = _painted(chat);
    // Header only: the subject, its outcome, and nothing of the output.
    expect(painted, contains(' → bash · echo hi'));
    expect(painted, contains('ok'));
    expect(painted, isNot(contains('line one')));
    expect(painted, isNot(contains('line two')));
    // The output is what a fold will reveal, so it is kept in full.
    expect(_bodyOf(sink), 'line one\nline two\n');
  });

  test('a long stream never reaches the chat, and is kept whole', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);
    final long = 'x' * 700;

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'find .'}));
    sink.toolOutput(ToolOutputEvent('bash', 't1', long));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    final painted = _painted(chat);
    // A 700-char dump costs one row: the header. No cap, no pointer — the
    // output simply is not the chat's business any more.
    expect(painted, contains(' → bash · find .'));
    expect(painted, contains('ok'));
    expect(painted.length, lessThan(120));
    expect(painted, isNot(contains('xxx')));
    // The full output is preserved for the viewer and the block's fold.
    expect(_calls(sink).last.subject, contains('bash'));
    expect(_calls(sink).last.body, isNotEmpty);
    expect(_bodyOf(sink), long);
  });

  test('a short call\'s output is retained too, not only a capped one', () {
    // The transcript shows a tool call as a header, so the output behind it has
    // to be kept whether or not the chat render ever hit the cap. Retaining
    // only capped calls would leave the common case with nothing to reveal.
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'ls'}));
    sink.toolOutput(const ToolOutputEvent('bash', 't1', 'a.dart\nb.dart\n'));
    sink.toolComplete(
        const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    expect(_calls(sink), hasLength(1));
    expect(_bodyOf(sink), 'a.dart\nb.dart\n');
    expect(_calls(sink).single.subject, contains('bash'));
  });

  test('a result that never streamed is retained verbatim', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);

    // A read/edit returns its payload as the result with no streamed chunks.
    sink.toolStart(const ToolStartEvent('read', 't2', {'filePath': 'a.dart'}));
    sink.toolComplete(const ToolCompleteEvent('read', 't2',
        isError: false, result: 'int x = 1;\n'));

    expect(_bodyOf(sink), 'int x = 1;\n');
  });

  test('a pathological dump is truncated at the retention limit', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);

    final huge = 'x' * (kBlockBodyLimit + 5000);
    sink.toolStart(const ToolStartEvent('bash', 't3', {'command': 'dump'}));
    sink.toolComplete(
        ToolCompleteEvent('bash', 't3', isError: false, result: huge));

    expect(_bodyOf(sink).length, lessThan(huge.length));
    expect(_bodyOf(sink), startsWith('x' * 100));
    expect(_bodyOf(sink), contains('truncated at $kBlockBodyLimit'));
  });

  group('elapsed in the status line', () {
    Future<String> finish(Duration? elapsed, {bool isError = false}) async {
      final io = FakeStdio();
      final screen = Screen.passthrough(io, ansi: AnsiCapable.no);
      final sink = ChatAgentSink(screen.chat, Spinner(enabled: false));
      sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
      sink.toolComplete(ToolCompleteEvent('bash', 't1',
          isError: isError, result: isError ? 'boom' : '', elapsed: elapsed));
      return io.written.toString();
    }

    test('a timed call shows its duration', () async {
      expect(await finish(const Duration(milliseconds: 41)),
          contains('  ok · 41ms'));
      expect(await finish(const Duration(milliseconds: 1400)),
          contains('  ok · 1.4s'));
      expect(await finish(const Duration(minutes: 2, seconds: 3)),
          contains('  ok · 2m 3s'));
    });

    test('an untimed call is unchanged', () async {
      expect(await finish(null), contains('  ok\n'));
    });

    test('a failure carries its duration without hiding the message',
        () async {
      final out =
          await finish(const Duration(milliseconds: 1400), isError: true);
      expect(out, contains('  failed (1.4s): boom'));
    });
  });

  test('a chunk boundary drops nothing', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolOutput(ToolOutputEvent('bash', 't1', 'a' * 400));
    sink.toolOutput(ToolOutputEvent('bash', 't1', 'b' * 400));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    final painted = _painted(chat);
    // Nothing of either chunk reaches the chat; both are retained whole, so a
    // chunk landing on a boundary cannot lose its tail.
    expect(painted, isNot(contains('a' * 20)));
    expect(painted, isNot(contains('b' * 20)));
    expect(_bodyOf(sink), '${'a' * 400}${'b' * 400}');
  });

  test('stderr after the cap is buffered, not printed', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolOutput(ToolOutputEvent('bash', 't1', 'x' * 700));
    sink.toolOutput(
        const ToolOutputEvent('bash', 't1', 'stderr tail', stderr: true));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

    expect(_painted(chat), isNot(contains('stderr tail')));
    expect(_bodyOf(sink), contains('stderr tail'));
  });

  test('a failure shows on the header, and the output is kept', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolOutput(ToolOutputEvent('bash', 't1', 'x' * 700));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1',
        isError: true, result: 'boom'));

    final painted = _painted(chat);
    // The failure is on the header — and so is the reason, since header-only
    // rendering hides the body. Here the streamed stderr dwarfs the one-word
    // result, so the stderr is what the header quotes.
    expect(painted, contains('failed · '));
    expect(painted, contains('xx'));
    expect(_bodyOf(sink), 'x' * 700);
  });

  // --- #49: tool-row head+tail truncation ---

  test('a long bash command keeps its tail, not just its head', () {
    // Narrow on purpose: the renderer truncates to the width it is given, so
    // this is the width that makes an 84-char command overflow.
    final chat = ScrollingTextRegion(_screen(width: 60));
    final sink = ChatAgentSink(chat, Spinner(enabled: false));
    // 84 chars: the `| sh` at the tail is what an approver needs to see.
    final cmd = 'a' * 80 + '| sh';

    sink.toolStart(ToolStartEvent('bash', 't1', {'command': cmd}));

    final row = _painted(chat)
        .split('\n')
        .firstWhere((l) => l.contains('→ bash ·'));
    // Both ends survive and the middle is what goes: the last characters — the
    // `| sh` an approver has to see — are still on the row.
    expect(row, contains('…'));
    expect(row, endsWith('| sh'));
    expect(row, isNot(contains('a' * 53)));
  });

  test('a short bash command renders verbatim', () {
    final chat = ScrollingTextRegion(_screen(width: 200));
    final sink = ChatAgentSink(chat, Spinner(enabled: false));

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'echo hi'}));

    final row = _painted(chat)
        .split('\n')
        .firstWhere((l) => l.contains('→ bash · echo hi'));
    expect(row, contains(' → bash · echo hi'));
  });

  test('a command the panel can hold is rendered whole', () {
    final chat = ScrollingTextRegion(_screen(width: 200));
    final sink = ChatAgentSink(chat, Spinner(enabled: false));
    final cmd = 'b' * 80;

    sink.toolStart(ToolStartEvent('bash', 't1', {'command': cmd}));

    final row = _painted(chat)
        .split('\n')
        .firstWhere((l) => l.contains('→ bash ·'));
    // There is no fixed budget any more: what fits is what fits.
    expect(row, contains('→ bash · $cmd'));
    expect(row, isNot(contains('…')));
  });

  test('a long k=v summary keeps both its head and its tail', () {
    final chat = ScrollingTextRegion(_screen(width: 60));
    final sink = ChatAgentSink(chat, Spinner(enabled: false));
    final value = 'HEAD' + 'x' * 90 + 'TAIL';

    sink.toolStart(ToolStartEvent('mytool', 't1', {'text': value}));

    final row = _painted(chat)
        .split('\n')
        .firstWhere((l) => l.contains('→ mytool ·'));
    expect(row, contains('mytool · text=HEAD')); // head survives
    expect(row, contains('…'));
    expect(row, endsWith('TAIL')); // and so does the tail
    // The middle is what truncation cut: no long run of `x` survives whole.
    expect(row, isNot(contains('x' * 49)));
  });

  // --- #50: failed tool results reach the /output ring when cut ---

  test(
      'a failed call with a long result and no stream caps the line but '
      'keeps the full error for /output', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);
    final result = 'E' * 250 + 'THE REAL ERROR TAIL';

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolComplete(ToolCompleteEvent('bash', 't1',
        isError: true, result: result));

    final painted = _painted(chat);
    // (1) The failure, and as much of the reason as a header can hold.
    expect(painted, contains('failed · EEE'));
    expect(painted, isNot(contains('THE REAL ERROR TAIL')));
    // (2) There is no pointer row any more: the header itself is the pointer,
    //     and the block's fold is where the output lives.
    expect(painted, isNot(contains('/output')));
    // (3) The block's body carries the FULL result.
    expect(_calls(sink), hasLength(1));
    expect(_bodyOf(sink), result);
    expect(_bodyOf(sink), contains('THE REAL ERROR TAIL'));
    expect(_calls(sink).single.subject, contains('bash'));
  });

  test('a failed call with a short result stays as before', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolComplete(const ToolCompleteEvent('bash', 't1',
        isError: true, result: 'boom'));

    final painted = _painted(chat);
    expect(painted, contains('failed · boom'));
    expect(_bodyOf(sink), 'boom');
  });

  test('a successful call is one row with its outcome', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false),);
    final result = 'r' * 500; // far past 200 chars — still no failure path

    sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'go'}));
    sink.toolComplete(ToolCompleteEvent('bash', 't1',
        isError: false, result: result));

    final painted = _painted(chat);
    expect(painted, contains('  ok'));
    expect(painted, isNot(contains('/output')));
    expect(_bodyOf(sink), result);
  });

  group('the transcript', () {
    test('the user gets its own block, same as any other row', () {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false),
          speaker: const ChatSpeaker(id: 'c1', label: 'main'));

      sink.userMessage('why is CI red?');
      sink.text('Looking at the failing job.\n');
      sink.newline();

      final painted = _painted(chat);
      expect(painted, contains(' why is CI red?'));
      expect(painted, contains(' Looking at the failing job.'));
    });

    test('rows are anonymous — the speaker label reaches the panel, not them',
        () {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false),
          speaker: const ChatSpeaker(id: 'c2', label: 'scout'));

      sink.text('on the trail\n');
      sink.newline();

      // A delegated conversation is named by its panel title; its rows look
      // like every other conversation's.
      expect(_painted(chat), contains(' on the trail'));
      expect(_painted(chat), isNot(contains('scout')));
    });

    test('reasoning is a counted row, not the thought', () {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false));

      sink.reasoning('let me think about', startsBlock: true);
      sink.reasoning(' this for a while');
      sink.reasoningEnd(complete: true);

      final painted = _painted(chat);
      expect(painted, contains('▸ reasoning  35 chars'));
      expect(painted, isNot(contains('let me think about')));
    });

    test('a truncated thought says so', () {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false));

      sink.reasoning('half a thought', startsBlock: true);
      sink.reasoningEnd(complete: false);

      expect(_painted(chat), contains('▸ reasoning (partial)'));
    });

    test('severity is a word a reader can see without colour', () {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false));

      sink.notice('retrying after a 502\n', kind: NoticeKind.warning);
      sink.notice('the run failed\n', kind: NoticeKind.error);
      sink.notice('just so you know\n');

      final painted = _painted(chat);
      expect(painted, contains('warn · retrying after a 502'));
      expect(painted, contains('error · the run failed'));
      expect(painted, contains(' just so you know'));
    });

    test('a resize re-lays the transcript out at the new width', () {
      final io = FakeStdio()..columns = 120;
      final screen = Screen(
          io: io,
          layout: ScreenLayout.fromSize(120, 24),
          ansi: AnsiCapable.yes);
      final chat = ScrollingTextRegion(screen);
      final sink = ChatAgentSink(chat, Spinner(enabled: false));

      sink.text('a paragraph long enough that the two widths disagree about '
          'where its lines should break\n');
      sink.newline();
      final wide = _painted(chat);

      // Narrow the panel under the transcript, as a terminal resize does.
      screen.resize(ScreenLayout.fromSize(60, 24));
      chat.handleResize();
      sink.rerender();
      final narrow = _painted(chat);

      expect(wide, isNot(equals(narrow)),
          reason: 'the same paragraph wraps differently at 60 columns');
      for (final line in narrow.split('\n').where((l) => l.isNotEmpty)) {
        expect(plainWidth(line), lessThanOrEqualTo(chat.bounds.width),
            reason: 'every row still fits the narrower panel');
      }
    });
  });

  test('the fold hint appears once, when folding first becomes possible', () {
    final chat = ScrollingTextRegion(_screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false));

    // Prose cannot fold, so it earns no hint.
    sink.text('a paragraph\n');
    sink.newline();
    expect(_painted(chat), isNot(contains(kFoldHint)));

    for (var i = 0; i < 2; i++) {
      sink.toolStart(ToolStartEvent('bash', 't$i', {'command': 'cmd$i'}));
      sink.toolOutput(ToolOutputEvent('bash', 't$i', 'body-$i\n'));
      sink.toolComplete(
          ToolCompleteEvent('bash', 't$i', isError: false, result: ''));
    }

    final painted = _painted(chat);
    expect(painted, contains(' $kFoldHint'));
    expect(kFoldHint.allMatches(painted).length, 1,
        reason: 'the second call has nothing new to announce');
  });

  group('folding', () {
    /// A sink with one tool call whose output was retained.
    (ScrollingTextRegion, ChatAgentSink) withTool() {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false));
      sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'ls'}));
      sink.toolOutput(const ToolOutputEvent('bash', 't1', 'a.dart\nb.dart\n'));
      sink.toolComplete(
          const ToolCompleteEvent('bash', 't1', isError: false, result: ''));
      return (chat, sink);
    }

    test('a tool call opens its body in place', () {
      final (chat, sink) = withTool();
      expect(_painted(chat), isNot(contains('a.dart')));
      expect(_calls(sink).single.folded, isTrue);

      expect(sink.toggleFold(0), isTrue);
      final expanded = _painted(chat);
      // Header, then the output nested one level in.
      expect(expanded, contains('→ bash · ls  ok'));
      expect(expanded, contains('a.dart'));
      expect(expanded, contains('b.dart'));
      expect(expanded, contains('   a.dart'));

      // And back again.
      expect(sink.toggleFold(0), isTrue);
      expect(_painted(chat), isNot(contains('a.dart')));
    });

    test('prose and user messages never fold', () {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false));
      sink.userMessage('hello');
      sink.text('a paragraph\n');
      sink.newline();

      expect(sink.toggleFold(0), isFalse, reason: "the user's own words");
      expect(sink.toggleFold(1), isFalse, reason: 'prose');
      expect(_painted(chat), contains('hello'));
      expect(_painted(chat), contains('a paragraph'));
    });

    test('a call with nothing behind it cannot fold', () {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false));
      // A decline never streams and returns no result.
      sink.toolStart(const ToolStartEvent('bash', 't1', {'command': 'ls'}));
      sink.toolComplete(
          const ToolCompleteEvent('bash', 't1', isError: false, result: ''));

      expect(sink.toggleFold(0), isFalse);
    });

    test('fold all and unfold all skip what cannot fold', () {
      final (chat, sink) = withTool();
      sink.toolStart(const ToolStartEvent('read', 't2', {'filePath': 'x'}));
      sink.toolComplete(const ToolCompleteEvent('read', 't2',
          isError: false, result: 'int x;', elapsed: Duration.zero));
      sink.text('prose\n');
      sink.newline();

      expect(sink.setAllFolds(folded: false), 2);
      expect(_painted(chat), contains('int x;'));
      expect(sink.setAllFolds(folded: true), 2);
      expect(_painted(chat), isNot(contains('int x;')));
      // Idempotent, and only the two foldable blocks are counted — the prose
      // sitting between them is not one of them.
      expect(sink.setAllFolds(folded: true), 0);
      expect(sink.setAllFolds(folded: false), 2);
    });

    test('folding a middle block shifts the rows after it, with no stale rows',
        () {
      final chat = ScrollingTextRegion(_screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false));
      for (var i = 0; i < 3; i++) {
        sink.toolStart(ToolStartEvent('bash', 't$i', {'command': 'cmd$i'}));
        sink.toolOutput(ToolOutputEvent('bash', 't$i', 'body-$i\n'));
        sink.toolComplete(
            ToolCompleteEvent('bash', 't$i', isError: false, result: ''));
      }
      // Expand the first: two extra rows appear, and everything after shifts.
      sink.toggleFold(0);
      final lines = _painted(chat).split('\n');
      expect(lines.where((l) => l.contains('body-0')), hasLength(1));
      // Every row is still one of the three calls' rows: nothing from before
      // the rewrite is left painted underneath.
      expect(lines.where((l) => l.contains('→ bash ·')), hasLength(3));

      // Collapse it again: the rows it added must be gone, not just unindexed.
      sink.toggleFold(0);
      expect(_painted(chat), isNot(contains('body-0')));
      expect(_painted(chat).split('\n').where((l) => l.contains('→ bash ·')),
          hasLength(3));
    });
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
    expect(noticeRow.single, ' [watchdog] turn idle for 5m');
  });
}
