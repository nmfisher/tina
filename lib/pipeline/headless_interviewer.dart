import 'package:attractor/attractor.dart';

/// Existing noninteractive human-gate behavior, without terminal dependencies.
class HeadlessInterviewer implements Interviewer {
  const HeadlessInterviewer();

  @override
  Future<Answer> ask(Question question) async {
    switch (question.type) {
      case QuestionType.yesNo:
      case QuestionType.confirmation:
        return const Answer(kind: AnswerValue.yes, value: 'yes');
      case QuestionType.multipleChoice:
        final options = question.options ?? const <Option>[];
        return options.isEmpty
            ? const Answer.cancelled()
            : Answer(value: options.first.key, selectedOption: options.first);
      case QuestionType.freeform:
        return const Answer(text: '', value: '');
    }
  }

  @override
  Future<void> inform(String message, {String? stage}) async {}
}
