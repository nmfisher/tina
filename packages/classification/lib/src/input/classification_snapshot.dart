enum ClassificationExchangePhase { pending, complete, failed, cancelled }

final class ClassificationOutcome {
  const ClassificationOutcome(this.label, {this.unclear = false});
  final String label;
  final bool unclear;
}

/// Detached diagnostics. No execution or cancellation authority.
final class ClassificationTraceSnapshot {
  ClassificationTraceSnapshot({
    required this.revision,
    required Iterable<ClassificationExchangeSnapshot> exchanges,
  }) : exchanges = List.unmodifiable(exchanges);
  final int revision;
  final List<ClassificationExchangeSnapshot> exchanges;
}

final class ClassificationExchangeSnapshot {
  ClassificationExchangeSnapshot({
    required this.id,
    this.parentId,
    required this.classifierId,
    required this.classifierName,
    this.trigger,
    this.inputText,
    this.outcome,
    required Map<String, Object?> questions,
    required Map<String, Object?> answers,
    required this.inputId,
    required this.title,
    required this.request,
    required this.started,
    required this.response,
    this.error,
    this.elapsed,
    required this.phase,
    required this.pending,
  }) : questions = _freeze(questions) as Map<String, Object?>,
       answers = _freeze(answers) as Map<String, Object?>;
  final int id;
  final int? parentId;
  final String classifierId, classifierName;
  final String? trigger, inputText;
  final ClassificationOutcome? outcome;
  final Map<String, Object?> questions, answers;
  final String inputId, title, request, response;
  final DateTime started;
  final String? error;
  final Duration? elapsed;
  final ClassificationExchangePhase phase;
  final bool pending;

  factory ClassificationExchangeSnapshot.fromJson(Map data) =>
      ClassificationExchangeSnapshot(
        id: data['id'] as int,
        parentId: data['parent_id'] as int?,
        classifierId: data['classifier_id'] as String,
        classifierName: data['classifier_name'] as String,
        trigger: data['trigger'] as String?,
        inputText: data['input_text'] as String?,
        outcome: data['outcome'] == null
            ? null
            : ClassificationOutcome(
                data['outcome'] as String,
                unclear: data['unclear'] == true,
              ),
        questions: Map<String, Object?>.from(data['questions'] as Map),
        answers: Map<String, Object?>.from(data['answers'] as Map),
        inputId: data['input_id'] as String,
        title: data['title'] as String,
        request: data['request'] as String,
        response: data['response'] as String,
        started: DateTime.parse(data['started'] as String),
        error: data['error'] as String?,
        elapsed: data['elapsed_ms'] == null
            ? null
            : Duration(milliseconds: data['elapsed_ms'] as int),
        phase: ClassificationExchangePhase.values.byName(
          data['phase'] as String,
        ),
        pending: data['pending'] as bool,
      );
}

Object? _freeze(Object? value) => switch (value) {
  Map value => Map<String, Object?>.unmodifiable(
    value.map((key, item) => MapEntry(key as String, _freeze(item))),
  ),
  List value => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
