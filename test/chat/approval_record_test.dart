import 'package:tina/chat/chat_agent_sink.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// The settled approval record — queued by the permission modal, which answers
/// *before* the engine ever starts the tool — has to land in the transcript
/// exactly once, *after* the tool row it belongs to, and has to survive the
/// repaint the call's completion triggers.
void main() {
  Screen screen({int width = 400}) => Screen(
    io: FakeStdio()..columns = width,
    layout: ScreenLayout.fromSize(width, 24),
  );

  /// The region's painted rows, joined — what the user would see in the chat.
  String paintedOf(ScrollingTextRegion chat) {
    final buf = StringBuffer();
    for (var i = 0; i < 40; i++) {
      final t = chat.debugPaintedText(i);
      if (t == null) break;
      buf.writeln(t.trimRight());
    }
    return buf.toString();
  }

  const record = '  Run shell command · allow once\n';

  test('the record prints once, after the row, and survives completion', () {
    final chat = ScrollingTextRegion(screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false));

    // Queued while the modal is open — i.e. before the tool starts.
    sink.queueApproval(record);
    sink.toolStart(
      const ToolStartEvent('bash', 't1', {'command': 'git status'}),
    );
    sink.toolOutput(const ToolOutputEvent('bash', 't1', 'branch main\n'));
    sink.toolComplete(
      const ToolCompleteEvent('bash', 't1', isError: false, result: ''),
    );

    final painted = paintedOf(chat);
    final row = painted.indexOf('→ bash · git status');
    final approval = painted.indexOf('Run shell command · allow once');
    expect(row, greaterThanOrEqualTo(0));
    expect(
      approval,
      greaterThan(row),
      reason: 'the record follows its tool row, never precedes it',
    );
    expect(
      RegExp('git status').allMatches(painted),
      hasLength(1),
      reason: 'the call is printed once — by its row, not by the record too',
    );
    expect(
      RegExp('allow once').allMatches(painted),
      hasLength(1),
      reason:
          'and the approval itself prints once, after the completion '
          'repaint has had its say',
    );
  });

  test('passthrough prints row then record, in that order', () {
    final stdio = FakeStdio()..columns = 400;
    final screen = Screen.passthrough(stdio);
    final sink = ChatAgentSink(screen.chat, Spinner(enabled: false));

    sink.queueApproval(record);
    sink.toolStart(
      const ToolStartEvent('bash', 't1', {'command': 'git status'}),
    );
    sink.toolComplete(
      const ToolCompleteEvent('bash', 't1', isError: false, result: ''),
    );

    final out = stdio.written.toString();
    final row = out.indexOf('→ bash: git status');
    final approval = out.indexOf('Run shell command · allow once');
    expect(row, greaterThanOrEqualTo(0));
    expect(approval, greaterThan(row));
    expect(RegExp('git status').allMatches(out), hasLength(1));
    expect(RegExp('allow once').allMatches(out), hasLength(1));
  });

  test('a denied call gets no row: the record names it before the denial', () {
    final chat = ScrollingTextRegion(screen());
    final sink = ChatAgentSink(chat, Spinner(enabled: false));

    sink.queueApproval('  bash: git status · deny once\n');
    sink.notice('  bash denied\n');

    final painted = paintedOf(chat);
    final record = painted.indexOf('bash: git status · deny once');
    final denial = painted.indexOf('bash denied');
    expect(record, greaterThanOrEqualTo(0));
    expect(denial, greaterThan(record));
    expect(painted, isNot(contains('→ bash')));
  });

  test(
    'a record for a call that never started prints before the next prose',
    () {
      final chat = ScrollingTextRegion(screen());
      final sink = ChatAgentSink(chat, Spinner(enabled: false));

      sink.queueApproval('  bash: git status · cancelled\n');
      sink.text('Next answer.\n');
      sink.newline();

      final painted = paintedOf(chat);
      final record = painted.indexOf('bash: git status · cancelled');
      expect(record, greaterThanOrEqualTo(0));
      expect(painted.indexOf('Next answer'), greaterThan(record));
    },
  );
}
