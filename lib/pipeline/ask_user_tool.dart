import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';

/// `ask_user` — pose one or more multiple-choice questions to the user,
/// rendered as an arrow-key selection form (↑/↓ option, ←/→ question, Enter
/// confirms). The chosen labels come back as the tool result, so the agent can
/// act on them. Uses the same [Question]/[Answer] vocabulary as the workflow
/// `wait.human` gates.
class AskUserTool implements Tool {
  AskUserTool(this._ask);

  /// Renders the questions and returns the user's answers. null in headless —
  /// the tool then auto-selects the first option of each question (the gate
  /// precedent) and says so.
  final Future<List<Answer>> Function(List<Question>)? _ask;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'ask_user',
        description: 'Pose multiple-choice questions to the user and get '
            'their answers. Use only when a decision is genuinely the user\'s '
            '(choosing between approaches, approving a plan detail) — never '
            'for work you can decide yourself. Pass `questions` as a list of '
            '{"text": <question>, "options": [<choices>]}; keep options '
            'concise. The user navigates with ↑/↓ and ←/→ and confirms with '
            'Enter; your result lists the chosen option for each question.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'questions': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string'},
                  'options': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                },
                'required': ['text', 'options'],
              },
            },
          },
          'required': ['questions'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final raw = input['questions'];
    if (raw is! List || raw.isEmpty) {
      return ToolResult.error('ask_user needs a non-empty `questions` list.');
    }

    final questions = <Question>[];
    for (final r in raw) {
      if (r is! Map) return ToolResult.error('malformed question entry.');
      final text = (r['text'] as String?)?.trim() ?? '';
      final opts = (r['options'] as List?)?.cast<String>() ?? const <String>[];
      if (text.isEmpty || opts.isEmpty) {
        return ToolResult.error('each question needs `text` and at least one '
            '`options` entry.');
      }
      questions.add(Question(
        text: text,
        type: QuestionType.multipleChoice,
        options: [
          for (var i = 0; i < opts.length; i++)
            Option(key: '${i + 1}', label: opts[i]),
        ],
      ));
    }

    final ask = _ask;
    final List<Answer> answers;
    var headlessNote = '';
    if (ask == null) {
      // Headless: no UI — auto-select the first option of each question (the
      // same policy workflow gates use), and say so honestly.
      answers = [
        for (final q in questions)
          Answer(value: q.options!.first.key, selectedOption: q.options!.first),
      ];
      headlessNote = ' (headless — auto-selected the first option)';
    } else {
      answers = await ask(questions);
      if (answers.isEmpty) {
        return ToolResult.error('ask_user cancelled');
      }
    }

    final buf = StringBuffer();
    for (var i = 0; i < questions.length; i++) {
      final chosen = i < answers.length
          ? (answers[i].selectedOption?.label ?? answers[i].value ?? '')
          : '';
      buf.writeln('Q${i + 1} ${questions[i].text}: $chosen$headlessNote');
    }
    return ToolResult(buf.toString().trimRight());
  }
}
