import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_tui/tina_tui.dart';

/// Headless: feed events, assert rows. A provider decorator will feed this
/// exactly the same events in production.
void main() {
  test('a delta sequence then a completion renders the accumulated answer',
      () {
    final view = StreamView();
    view.apply(const TextDelta('Hello'));
    view.apply(const TextDelta(', world'));
    view.apply(const ReasoningDelta('pondering'));
    view.apply(const MessageComplete(
      content: [TextBlock('Hello, world — final')],
      stopReason: 'end_turn',
    ));

    expect(view.isComplete, isTrue);
    final texts = view.rows.map((r) => r.runs.map((run) => run.text).join());
    expect(texts, ['Hello, world — final']);
  });

  test('mid-stream rows show reasoning, text and open chips', () {
    final view = StreamView();
    view.apply(const ReasoningDelta('checking the ledger'));
    view.apply(const TextDelta('Working on it'));
    view.apply(const ToolCallStart(id: 'c1', name: 'read'));

    expect(view.isComplete, isFalse);
    final texts = view.rows.map((r) => r.runs.map((run) => run.text).join());
    expect(texts, [
      '· checking the ledger',
      'Working on it',
      '⏺ read', // no args: ToolCallStart carries id+name only
    ]);
  });

  test('completion replaces the streamed accumulation', () {
    final view = StreamView();
    view.apply(const TextDelta('partial'));
    view.apply(const ToolCallStart(id: 'c1', name: 'bash'));
    view.apply(const MessageComplete(
      content: [
        TextBlock('done'),
        ToolUseBlock(id: 'c9', name: 'write',
            input: {'path': 'a.txt'}),
        ToolResultBlock(toolUseId: 'c9', content: 'ok'),
      ],
      stopReason: 'tool_use',
    ));
    final texts = view.rows.map((r) => r.runs.map((run) => run.text).join());
    expect(texts, ['done', startsWith('⏺ write'), '  ↳ ok']);
  });

  test('notices and errors after completion do not repaint the turn', () {
    final view = StreamView();
    view.apply(const MessageComplete(
      content: [TextBlock('final')],
      stopReason: 'end_turn',
    ));
    view.apply(const StreamNotice('straggler notice'));
    view.apply(StreamError(StateError('boom')));
    expect(view.rows.single.runs.single.text, 'final');
  });

  test('a fresh TextDelta after completion starts a new accumulation', () {
    final view = StreamView();
    view.apply(const MessageComplete(
      content: [TextBlock('turn one')],
      stopReason: 'end_turn',
    ));
    view.apply(const TextDelta('next '));
    expect(view.isComplete, isFalse); // reset, not append
    expect(view.rows.single.runs.single.text, 'next ');
  });

  test('StreamError shows nothing; the loop owns errors', () {
    final view = StreamView();
    view.apply(const TextDelta('so far'));
    view.apply(StreamError(StateError('boom')));
    final texts = view.rows.map((r) => r.runs.map((run) => run.text).join());
    expect(texts, ['so far']);
  });

  test('rows layout at the configured width', () {
    final view = StreamView(width: 30);
    view.apply(const ToolCallStart(
        id: 'c1', name: 'bash'));
    view.apply(const MessageComplete(
      content: [
        ToolUseBlock(
          id: 'c1',
          name: 'bash',
          input: {
            'command':
                'a-long-command-that-keeps-going-and-going'
          },
        ),
      ],
      stopReason: 'tool_use',
    ));
    for (final row in view.rows) {
      expect(
        row.runs.fold<int>(0, (w, r) => w + visibleWidth(r.text)),
        lessThanOrEqualTo(30),
      );
    }
  });
}
