import 'package:attractor/attractor.dart';
import 'package:tina/pipeline/ask_user_tool.dart';
import 'package:test/test.dart';

/// Pins [AskUserTool]: schema parsing into attractor [Question]s, the answer
/// round-trip, the cancelled path, and the headless auto-answer fallback.
void main() {
  test('poses the parsed questions and returns the chosen labels', () async {
    List<Question>? received;
    final tool = AskUserTool((questions) async {
      received = questions;
      return [
        Answer(
          value: 'B: rewrite',
          selectedOption: questions[0].options![1],
        ),
        Answer(
          value: 'C: minimal',
          selectedOption: questions[1].options![0],
        ),
      ];
    });

    final r = await tool.execute({
      'questions': [
        {'text': 'Which approach?', 'options': ['A: refactor', 'B: rewrite']},
        {'text': 'How far?', 'options': ['C: minimal', 'D: full']},
      ],
    });

    expect(r.isError, isFalse);
    expect(received, hasLength(2));
    expect(received![0].text, 'Which approach?');
    expect(received![0].type, QuestionType.multipleChoice);
    expect(
        [for (final o in received![0].options!) o.label],
        ['A: refactor', 'B: rewrite']);
    expect(r.content, contains('Q1 Which approach?: B: rewrite'));
    expect(r.content, contains('Q2 How far?: C: minimal'));
  });

  test('a cancelled form surfaces as a tool error', () async {
    final tool = AskUserTool((questions) async => const []);
    final r = await tool.execute({
      'questions': [
        {'text': 'Q?', 'options': ['a', 'b']},
      ],
    });
    expect(r.isError, isTrue);
    expect(r.content, contains('cancelled'));
  });

  test('malformed input errors before asking', () async {
    var asked = false;
    final tool = AskUserTool((questions) async {
      asked = true;
      return const [];
    });
    expect(
        (await tool.execute({'questions': []})).isError, isTrue);
    expect(
        (await tool.execute({'questions': [
          {'text': 'no options'}
        ]})).isError,
        isTrue);
    expect(asked, isFalse);
  });

  test('headless (no asker) auto-selects the first option and says so',
      () async {
    final tool = AskUserTool(null);
    final r = await tool.execute({
      'questions': [
        {'text': 'Q1', 'options': ['first', 'second']},
        {'text': 'Q2', 'options': ['x', 'y']},
      ],
    });
    expect(r.isError, isFalse);
    expect(r.content, contains('Q1: first'));
    expect(r.content, contains('Q2: x'));
    expect(r.content, contains('headless — auto-selected the first option'));
  });

  test('the schema is a wire-valid JSON-Schema object', () {
    final schema = AskUserTool(null).schema;
    expect(schema.inputSchema['type'], 'object');
    expect(schema.inputSchema['properties'], isA<Map>());
  });
}
