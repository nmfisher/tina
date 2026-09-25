import 'package:tina/chat/chat_agent_sink.dart';
import 'package:tina/chat/chat_transcript.dart';
import 'package:tina/tui/transcript_cursor.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// The Ctrl+B transcript cursor: stepping, toggling, and the mark it leaves.
/// Keys are injected, so this needs no terminal and no timing.
void main() {
  late Screen screen;
  late ScrollingTextRegion chat;
  late ChatAgentSink sink;
  late LineEditor editor;
  late FakeStdio io;

  setUp(() {
    io = FakeStdio()..columns = 200;
    screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(200, 24),
      ansi: AnsiCapable.yes,
    );
    chat = ScrollingTextRegion(screen);
    sink = ChatAgentSink(chat, Spinner(enabled: false));
    editor = LineEditor(screen: screen);
  });

  String painted() {
    final buf = StringBuffer();
    for (var i = 0; i < 30; i++) {
      final t = chat.debugPaintedText(i);
      if (t == null) break;
      buf.writeln(t.trimRight());
    }
    return buf.toString();
  }

  /// Three tool calls, each with output behind its header.
  void threeCalls() {
    for (var i = 0; i < 3; i++) {
      sink.toolStart(ToolStartEvent('bash', 't$i', {'command': 'cmd$i'}));
      sink.toolOutput(ToolOutputEvent('bash', 't$i', 'body-$i\n'));
      sink.toolComplete(
        ToolCompleteEvent('bash', 't$i', isError: false, result: ''),
      );
    }
  }

  /// The tool calls under test. The transcript also carries the one-off fold
  /// hint as a notice, so assertions index these rather than the raw list.
  List<ChatBlock> calls() =>
      sink.blocks.where((b) => b.kind == ChatBlockKind.toolCall).toList();

  /// Drives the cursor with [keys], then Escapes out.
  Future<void> drive(List<InputEvent> keys) {
    final queue = [...keys, EscapeKey()];
    return runTranscriptCursor(
      editor: editor,
      chat: chat,
      transcript: sink,
      readEvent: () async => queue.removeAt(0),
    );
  }

  test('nothing to read means it does not even take the keyboard', () async {
    var reads = 0;
    await runTranscriptCursor(
      editor: editor,
      chat: chat,
      transcript: sink,
      readEvent: () async {
        reads++;
        return EscapeKey();
      },
    );
    expect(reads, 0, reason: 'an empty transcript is not a mode to enter');
  });

  test('it starts on the newest foldable block', () async {
    threeCalls();
    // Nothing asserted mid-loop, so just confirm entering and leaving is clean.
    await drive([]);
    expect(calls().every((b) => b.folded), isTrue);
    expect(
      painted(),
      isNot(contains('\x1b[33m')),
      reason: 'the mark is cleared on the way out',
    );
  });

  test(
    'enter reveals the focused block, and space collapses it again',
    () async {
      threeCalls();
      // The cursor starts on the newest (block 2); step up once to block 1.
      await drive([ArrowKey(ArrowDirection.up), ControlKey(ControlCode.enter)]);
      expect(
        calls()[1].folded,
        isFalse,
        reason: 'enter opened the block the cursor was on',
      );
      expect(painted(), contains('body-1'));

      await drive([ArrowKey(ArrowDirection.up), CharInput(' ')]);
      expect(
        calls()[1].folded,
        isTrue,
        reason: 'space closed it again (the cursor starts on 2, up to 1)',
      );
      expect(painted(), isNot(contains('body-1')));
    },
  );

  test('arrows stop at the ends instead of wrapping', () async {
    threeCalls();
    // Three ups from the newest would wrap past the oldest if it wrapped.
    await drive([
      ArrowKey(ArrowDirection.up),
      ArrowKey(ArrowDirection.up),
      ArrowKey(ArrowDirection.up),
      ControlKey(ControlCode.enter),
    ]);
    expect(calls()[0].folded, isFalse, reason: 'clamped at the oldest block');
    expect(calls()[1].folded, isTrue);
    expect(calls()[2].folded, isTrue);
  });

  test('the mark follows the cursor while it is open', () async {
    threeCalls();
    final keys = <InputEvent>[
      ArrowKey(ArrowDirection.up),
      // Inspect mid-loop: the mark should be on block 1 by now.
    ];
    await runTranscriptCursor(
      editor: editor,
      chat: chat,
      transcript: sink,
      readEvent: () async {
        if (keys.isNotEmpty) return keys.removeAt(0);
        // One look with the cursor still open, then leave.
        final marked = painted();
        expect(marked, contains('\x1b[33m'), reason: 'a mark is painted');
        return EscapeKey();
      },
    );
    expect(painted(), isNot(contains('\x1b[33m')));
  });

  test('a block that grows on reveal is scrolled back into view', () async {
    // Enough content above that the newest block starts near the bottom.
    for (var i = 0; i < 30; i++) {
      sink.notice('filler $i\n');
    }
    sink.toolStart(const ToolStartEvent('bash', 't', {'command': 'long'}));
    sink.toolOutput(
      ToolOutputEvent(
        'bash',
        't',
        [for (var i = 0; i < 20; i++) 'xxxx-line-$i'].join('\n'),
      ),
    );
    sink.toolComplete(
      const ToolCompleteEvent('bash', 't', isError: false, result: ''),
    );

    await drive([ControlKey(ControlCode.enter)]);
    expect(calls().last.folded, isFalse);
    // The *end* of the revealed block is what is on screen: revealing is a
    // question about the contents, so the header alone would be no answer.
    // A scrollback redraw deliberately clears the tail-row paint snapshots.
    // Inspect the actual viewport rather than assuming those snapshots exist.
    final terminal = VirtualTerminal(width: 200, height: 24)
      ..feed(io.written.toString());
    expect(
      [for (var row = 0; row < 24; row++) terminal.rowText(row)].join('\n'),
      contains('xxxx-line-19'),
    );
  });
}
