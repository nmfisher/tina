import 'package:tina/tui/input_recall.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// Regression tests for tin-hist — pressing ↑ in the input field must recall
/// only messages the OPERATOR sent. The startup replay feeds
/// [recallHistoryLines]; system-composed user-role messages (budget nudge,
/// permission-mode announcement, compaction summary) are marked
/// [Message.isSynthetic] by the engine and must never resurface in the text
/// field.
void main() {
  Message _user(String text, {bool synthetic = false}) => Message(
    role: Role.user,
    isSynthetic: synthetic,
    content: [TextBlock(text)],
  );

  test('keeps every operator prompt', () {
    final lines = recallHistoryLines([
      _user('first question'),
      const Message(role: Role.assistant, content: [TextBlock('answer')]),
      _user('second question'),
    ]);
    expect(lines, ['first question', 'second question']);
  });

  test('filters the permission-mode announcement', () {
    final lines = recallHistoryLines([
      _user('real prompt'),
      _user(
        'Runtime permission mode: ask. Actions follow the current '
        'permission policy.',
        synthetic: true,
      ),
    ]);
    expect(lines, [
      'real prompt',
    ], reason: 'the mode announcement used to resurface on ↑ (tin-hist)');
  });

  test('filters the budget nudge and compaction summary', () {
    final lines = recallHistoryLines([
      _user(
        '[budget] turn spend at 90% of the per-turn limit...',
        synthetic: true,
      ),
      _user(
        'Prior conversation summary:\n\nlots of context here',
        synthetic: true,
      ),
      const Message(
        role: Role.assistant,
        isSynthetic: true,
        content: [TextBlock('Got it — continuing from this summary.')],
      ),
      _user('next real prompt'),
    ]);
    expect(lines, ['next real prompt']);
  });

  test('legacy sessions without the marker keep their prompts', () {
    // Messages restored from an old journal have no 'synthetic' key and
    // deserialize with isSynthetic == false — the typed prompts must still
    // reach the recall history. (Pre-marker synthetic lines pass through
    // too; there is nothing left to distinguish them by, and new sessions
    // mark everything.)
    final restored = [
      Message.fromJson({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'an old typed prompt'},
        ],
      }),
    ];
    expect(recallHistoryLines(restored), ['an old typed prompt']);
    expect(restored.every((m) => !m.isSynthetic), isTrue);
  });

  test('tool-result batches and reasoning-only entries yield nothing', () {
    final lines = recallHistoryLines([
      Message(
        role: Role.user,
        content: const [
          ToolResultBlock(toolUseId: 't1', content: 'result text'),
        ],
      ),
      const Message(
        role: Role.assistant,
        content: [],
        reasoning: [ReasoningBlock('thinking')],
      ),
    ]);
    expect(lines, [
      '',
    ], reason: 'blank entries are dropped later by addHistory');
  });

  test('returns a fresh list — callers cannot mutate the input', () {
    final history = <Message>[_user('only')];
    final lines = recallHistoryLines(history);
    lines.add('smuggled');
    expect(recallHistoryLines(history), ['only']);
  });
}
