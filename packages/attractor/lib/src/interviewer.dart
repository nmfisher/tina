/// The kind of UI to present for a [Question].
enum QuestionType {
  /// Yes/no binary choice.
  yesNo,

  /// Select one option from a list.
  multipleChoice,

  /// Free-form text input.
  freeform,

  /// A yes/no confirmation (semantically distinct from [yesNo]).
  confirmation,
}

/// One selectable option for a [multipleChoice] question.
class Option {
  /// An accelerator key parsed from the edge label (e.g. `Y`, `A`).
  final String key;

  /// The display text.
  final String label;

  const Option({required this.key, required this.label});

  @override
  String toString() => '[$key] $label';
}

/// A question the engine presents to a human at a `hexagon`/human-gate node.
class Question {
  /// The question text (typically the node's label).
  final String text;

  /// Determines the UI and the valid answers.
  final QuestionType type;

  /// The choices for a [QuestionType.multipleChoice] question, derived from the
  /// node's outgoing edges.
  final List<Option>? options;

  /// Originating stage name, for display.
  final String? stage;

  const Question({
    required this.text,
    required this.type,
    this.options,
    this.stage,
  });
}

/// A sentinel value carried by an [Answer] for yes/no/confirm questions.
enum AnswerValue { yes, no, skipped, timeout }

/// A human's answer to a [Question].
class Answer {
  /// The selected option key (for multiple choice) or freeform text.
  final String? value;

  /// The full selected option, when applicable.
  final Option? selectedOption;

  /// For yes/no/confirm questions.
  final AnswerValue? kind;

  /// Free-text response (for [QuestionType.freeform]).
  final String? text;

  const Answer({this.value, this.selectedOption, this.kind, this.text});

  /// The user dismissed the question without answering.
  const Answer.cancelled()
      : value = null,
        selectedOption = null,
        kind = AnswerValue.skipped,
        text = null;

  bool get isCancelled => kind == AnswerValue.skipped || kind == AnswerValue.timeout;

  /// The label to route on: the selected option's label, the value, or the
  /// freeform text — whatever is present.
  String? get routeLabel =>
      selectedOption?.label ?? value ?? text;
}

/// The seam a host application implements to present human-gate questions. The
/// engine `await`s [ask] at a `hexagon` node; the host blocks (e.g. on a TUI
/// overlay or stdin) until the human answers.
abstract class Interviewer {
  Future<Answer> ask(Question question);

  /// Display an informational message (e.g. stage progress) to the human.
  Future<void> inform(String message, {String? stage});
}
