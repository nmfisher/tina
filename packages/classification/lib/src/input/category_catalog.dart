import 'git_classifier.dart' show gitCommands;

const maxInputCategories = 254;
const otherCategoryId = 'other';

/// A reusable category and the membership question sent to the classifier.
/// Input examples and conversation history are never part of this catalog.
final class InputCategory {
  InputCategory({
    required this.id,
    required this.label,
    required this.description,
    required this.question,
    this.selections = 0,
  }) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(id) ||
        const ['other', 'none', 'unknown'].contains(id) ||
        label.trim().isEmpty ||
        label.length > 80 ||
        description.trim().isEmpty ||
        description.length > 400 ||
        question.trim().isEmpty ||
        question.length > 240 ||
        selections < 0) {
      throw const FormatException('Invalid input category');
    }
  }
  final String id, label, description, question;
  final int selections;
  InputCategory selected() => InputCategory(
    id: id,
    label: label,
    description: description,
    question: question,
    selections: selections + 1,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'description': description,
    'question': question,
    'selections': selections,
  };
  factory InputCategory.fromJson(Map<String, Object?> json) => InputCategory(
    id: json['id'] as String,
    label: json['label'] as String,
    description: json['description'] as String,
    question: json['question'] as String,
    selections: json['selections'] as int,
  );
}

final class CategoryQuestion {
  CategoryQuestion({
    required this.id,
    required this.question,
    required Iterable<InputCategory> categories,
    this.otherSelections = 0,
  }) : categories = List.unmodifiable(categories) {
    if (id.trim().isEmpty ||
        question.trim().isEmpty ||
        this.categories.length > maxInputCategories ||
        this.categories.map((c) => c.id).toSet().length !=
            this.categories.length ||
        this.categories.map((c) => _name(c.label)).toSet().length !=
            this.categories.length ||
        otherSelections < 0) {
      throw const FormatException('Invalid category question');
    }
  }
  final String id, question;
  final List<InputCategory> categories;
  final int otherSelections;
  InputCategory? category(String id) {
    for (final category in categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  CategoryQuestion record(Iterable<String> selected) {
    final ids = selected.toSet();
    if (ids.any((id) => id != otherCategoryId && category(id) == null)) {
      throw const FormatException('Unknown selected category');
    }
    return CategoryQuestion(
      id: id,
      question: question,
      categories: [
        for (final c in categories) ids.contains(c.id) ? c.selected() : c,
      ],
      otherSelections:
          otherSelections + (ids.contains(otherCategoryId) ? 1 : 0),
    );
  }

  /// Reuse identical proposals, but never overwrite an existing definition.
  /// The caller must reclassify after adding/reusing a category.
  (CategoryQuestion, InputCategory?) learn(InputCategory proposed) {
    for (final existing in categories) {
      if (_name(existing.label) == _name(proposed.label))
        return (this, existing);
      if (existing.id == proposed.id) {
        throw const FormatException('Category ID collision');
      }
    }
    if (categories.length == maxInputCategories) return (this, null);
    final category = InputCategory(
      id: proposed.id,
      label: proposed.label,
      description: proposed.description,
      question: proposed.question,
    );
    return (
      CategoryQuestion(
        id: id,
        question: question,
        categories: [...categories, category],
        otherSelections: otherSelections,
      ),
      category,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'question': question,
    'other_selections': otherSelections,
    'categories': [for (final c in categories) c.toJson()],
  };
  factory CategoryQuestion.fromJson(Map<String, Object?> json) =>
      CategoryQuestion(
        id: json['id'] as String,
        question: json['question'] as String,
        otherSelections: json['other_selections'] as int,
        categories: [
          for (final raw in json['categories'] as List)
            InputCategory.fromJson(Map<String, Object?>.from(raw as Map)),
        ],
      );
}

String _name(String label) =>
    label.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

List<CategoryQuestion> initialCategoryQuestions() => [
  CategoryQuestion(
    id: 'intent',
    question: 'What best describes the latest user input?',
    categories: [
      InputCategory(
        id: 'projectQuestion',
        label: 'project question',
        description:
            'A question about the project, its code, architecture, design or behavior.',
        question: 'Does the latest input ask a question about the project?',
      ),
      InputCategory(
        id: 'agentInstruction',
        label: 'instruction',
        description: 'An instruction for the agent to perform a task.',
        question: 'Does the latest input instruct the agent to do something?',
      ),
    ],
  ),
  CategoryQuestion(
    id: 'git',
    question: 'Which Git operations does the latest input request?',
    categories: [
      for (final command in gitCommands.where((c) => c != otherCategoryId))
        InputCategory(
          id: command,
          label: command,
          description: 'A request to run git $command.',
          question: 'Does the latest input request git $command?',
        ),
    ],
  ),
];

/// The plugin owns the vocabulary; hosts only choose its storage location.
abstract interface class InputCategoryStore {
  Future<List<CategoryQuestion>> read();
  Future<void> record(String questionId, Iterable<String> selected);
  Future<InputCategory?> learn(String questionId, InputCategory proposed);
}

final class MemoryInputCategoryStore implements InputCategoryStore {
  MemoryInputCategoryStore([Iterable<CategoryQuestion>? questions])
    : _questions = List.of(questions ?? initialCategoryQuestions());
  List<CategoryQuestion> _questions;
  @override
  Future<List<CategoryQuestion>> read() async => List.unmodifiable(_questions);
  @override
  Future<void> record(String questionId, Iterable<String> selected) async {
    final index = _index(questionId);
    _questions[index] = _questions[index].record(selected);
  }

  @override
  Future<InputCategory?> learn(
    String questionId,
    InputCategory proposed,
  ) async {
    final index = _index(questionId);
    final (question, category) = _questions[index].learn(proposed);
    _questions[index] = question;
    return category;
  }

  int _index(String id) {
    final index = _questions.indexWhere((q) => q.id == id);
    if (index < 0) throw const FormatException('Unknown category question');
    return index;
  }
}
