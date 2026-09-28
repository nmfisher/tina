import 'dart:collection';

/// Immutable, JSON-only string/object/array. Rejects implicit `toJson` calls,
/// non-finite numbers, non-string map keys, and cyclic/over-deep values.
class JudgmentContent {
  final Object value;

  JudgmentContent(Object value) : value = _content(value);

  Object toJson() => value;
}

sealed class JudgmentQuestion<A extends JudgmentAnswer> {
  final String id;
  final JudgmentContent? instructions;

  JudgmentQuestion(this.id, {required Object? instructions})
    : instructions = instructions == null
          ? null
          : JudgmentContent(instructions) {
    _nonEmpty(id, 'question id');
  }

  String get type;
  Map<String, Object?> toJson();
  A _decode(Map<String, Object?> json);
}

final class ChoiceQuestion extends JudgmentQuestion<ChoiceAnswer> {
  final Map<String, Object?> criteria;

  ChoiceQuestion(
    super.id, {
    required super.instructions,
    required Map<String, Object?> criteria,
  }) : criteria = Map.unmodifiable(
         criteria.map(
           (key, value) =>
               MapEntry(key, value == null ? null : _content(value)),
         ),
       ) {
    if (criteria.isEmpty || criteria.length > 255) {
      throw ArgumentError('Choice requires 1 to 255 options');
    }
    for (final key in criteria.keys) {
      _nonEmpty(key, 'choice key');
    }
  }

  @override
  String get type => 'choice';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'instructions': instructions?.value,
    'criteria': criteria,
  };

  @override
  ChoiceAnswer _decode(Map<String, Object?> json) {
    final probabilities = _probabilities(json['probabilities'], criteria.keys);
    final choice = _string(json['choice']);
    if (!criteria.containsKey(choice)) _invalid('Unknown choice');
    return ChoiceAnswer._(
      choice,
      probabilities,
      _probability(json['confidence']),
    );
  }
}

final class ScoreQuestion extends JudgmentQuestion<ScoreAnswer> {
  final List<Object?> criteria;

  ScoreQuestion(
    super.id, {
    required super.instructions,
    required List<Object?> criteria,
  }) : criteria = List.unmodifiable(
         criteria.map((value) => value == null ? null : _content(value)),
       ) {
    if (criteria.length < 2 || criteria.length > 10) {
      throw ArgumentError('Score requires 2 to 10 levels');
    }
  }

  @override
  String get type => 'score';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'instructions': instructions?.value,
    'criteria': criteria,
  };

  @override
  ScoreAnswer _decode(Map<String, Object?> json) {
    final keys = List.generate(criteria.length, (i) => '$i');
    final probabilities = _probabilities(json['probabilities'], keys);
    final rawLegend = _map(json['legend']);
    _sameKeys(rawLegend.keys, keys);
    final legend = <int, Object?>{};
    for (var i = 0; i < criteria.length; i++) {
      final value = rawLegend['$i'];
      if (!_jsonEqual(value, criteria[i])) _invalid('Score legend mismatch');
      legend[i] = criteria[i];
    }
    final score = _number(json['score']);
    if (score < 0 || score > criteria.length - 1)
      _invalid('Score out of range');
    return ScoreAnswer._(
      score,
      Map.unmodifiable(legend),
      Map.unmodifiable(probabilities.map((k, v) => MapEntry(int.parse(k), v))),
      _probability(json['confidence']),
    );
  }
}

final class NoulQuestion extends JudgmentQuestion<NoulAnswer> {
  /// Optional structured descriptions, separately named to avoid stringly
  /// typed true/false keys in calling code.
  final JudgmentContent? whenTrue;
  final JudgmentContent? whenFalse;

  NoulQuestion(
    super.id, {
    required super.instructions,
    Object? whenTrue,
    Object? whenFalse,
  }) : whenTrue = whenTrue == null ? null : JudgmentContent(whenTrue),
       whenFalse = whenFalse == null ? null : JudgmentContent(whenFalse);

  @override
  String get type => 'noul';
  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'instructions': instructions?.value,
    if (whenTrue != null || whenFalse != null)
      'criteria': {
        if (whenTrue != null) 'true': whenTrue!.value,
        if (whenFalse != null) 'false': whenFalse!.value,
      },
  };

  @override
  NoulAnswer _decode(Map<String, Object?> json) =>
      NoulAnswer._(_probability(json['noul']));
}

class JudgmentRequest {
  final JudgmentContent state;
  final Map<String, JudgmentQuestion> questions;

  JudgmentRequest({
    required Object state,
    required Iterable<JudgmentQuestion> questions,
  }) : state = JudgmentContent(state),
       questions = _questions(questions);

  Map<String, Object?> toJson({required String model}) {
    _nonEmpty(model, 'model');
    return {
      'state': state.value,
      'model': model,
      'questions': questions.map(
        (id, question) => MapEntry(id, question.toJson()),
      ),
    };
  }
}

sealed class JudgmentAnswer {
  const JudgmentAnswer();
}

final class ChoiceAnswer extends JudgmentAnswer {
  final String choice;
  final Map<String, double> probabilities;
  final double confidence;
  const ChoiceAnswer._(this.choice, this.probabilities, this.confidence);
}

final class ScoreAnswer extends JudgmentAnswer {
  final double score;
  final Map<int, Object?> legend;
  final Map<int, double> probabilities;
  final double confidence;
  const ScoreAnswer._(
    this.score,
    this.legend,
    this.probabilities,
    this.confidence,
  );

  double get normalized => score / (legend.length - 1);
}

final class NoulAnswer extends JudgmentAnswer {
  /// Probability of yes. No confidence or implicit boolean threshold.
  final double noul;
  const NoulAnswer._(this.noul);
}

/// Missing counters stay unknown, never silently become zero.
class JudgmentUsage {
  final int? inputTokens;
  final int? outputTokens;
  const JudgmentUsage({this.inputTokens, this.outputTokens});
}

class JudgmentResult {
  final String model;
  final Map<String, JudgmentAnswer> answers;
  final JudgmentUsage usage;
  final Map<String, JudgmentQuestion> _questions;

  JudgmentResult._(this.model, this.answers, this.usage, this._questions);

  /// Validate the entire batch before exposing any answer to action policy.
  /// Unknown metadata fields are tolerated; missing/extra answers are not.
  factory JudgmentResult.fromJson(
    Object? value, {
    required JudgmentRequest request,
  }) {
    final json = _map(value);
    final model = _string(json['model']);
    final raw = _map(json['answers']);
    _sameKeys(raw.keys, request.questions.keys);
    final answers = <String, JudgmentAnswer>{};
    for (final entry in request.questions.entries) {
      final answer = _map(raw[entry.key]);
      if (answer['type'] != entry.value.type) _invalid('Answer type mismatch');
      answers[entry.key] = entry.value._decode(answer);
    }
    final usage = _map(json['usage']);
    return JudgmentResult._(
      model,
      Map.unmodifiable(answers),
      JudgmentUsage(
        inputTokens: _tokens(usage['input_tokens']),
        outputTokens: _tokens(usage['output_tokens']),
      ),
      request.questions,
    );
  }

  /// The question acts as a typed key; a same-ID question from another batch
  /// cannot accidentally retrieve an answer to different instructions/options.
  A answer<A extends JudgmentAnswer>(JudgmentQuestion<A> question) {
    if (!identical(_questions[question.id], question)) {
      throw ArgumentError('Question does not belong to this result');
    }
    return answers[question.id] as A;
  }
}

Map<String, JudgmentQuestion> _questions(Iterable<JudgmentQuestion> values) {
  final result = <String, JudgmentQuestion>{};
  for (final question in values) {
    if (result.containsKey(question.id))
      throw ArgumentError('Duplicate question id');
    result[question.id] = question;
  }
  if (result.isEmpty) throw ArgumentError('At least one question is required');
  return Map.unmodifiable(result);
}

void _nonEmpty(String value, String field) {
  if (value.trim().isEmpty) throw ArgumentError('$field must not be empty');
}

Object _content(Object value) {
  if (value is! String && value is! Map && value is! List) {
    throw ArgumentError('Content must be a JSON string, object, or array');
  }
  return _freeze(value, HashSet.identity(), 0)!;
}

Object? _freeze(Object? value, Set<Object> ancestors, int depth) {
  if (depth > 64) throw ArgumentError('JSON nesting exceeds 64 levels');
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  if (value is! List && value is! Map)
    throw ArgumentError('Invalid JSON value');
  if (!ancestors.add(value)) throw ArgumentError('Cyclic JSON value');
  try {
    if (value is List) {
      return List<Object?>.unmodifiable(
        value.map((v) => _freeze(v, ancestors, depth + 1)),
      );
    }
    final result = <String, Object?>{};
    for (final entry in (value as Map).entries) {
      if (entry.key is! String)
        throw ArgumentError('JSON keys must be strings');
      result[entry.key as String] = _freeze(entry.value, ancestors, depth + 1);
    }
    return Map<String, Object?>.unmodifiable(result);
  } finally {
    ancestors.remove(value);
  }
}

Never _invalid(String message) => throw FormatException(message);

Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String))
    _invalid('Expected object');
  return Map<String, Object?>.from(value);
}

String _string(Object? value) {
  if (value is! String || value.trim().isEmpty)
    _invalid('Expected nonempty string');
  return value;
}

double _number(Object? value) {
  if (value is! num || !value.isFinite) _invalid('Expected finite number');
  return value.toDouble();
}

double _probability(Object? value) {
  final number = _number(value);
  if (number < 0 || number > 1) _invalid('Probability out of range');
  return number;
}

void _sameKeys(Iterable<String> actual, Iterable<String> expected) {
  final keys = expected.toSet();
  if (actual.length != keys.length || !keys.containsAll(actual))
    _invalid('Keys mismatch');
}

Map<String, double> _probabilities(Object? value, Iterable<String> keys) {
  final raw = _map(value);
  _sameKeys(raw.keys, keys);
  final result = raw.map((k, v) => MapEntry(k, _probability(v)));
  // Permit rounded wire probabilities, but never normalize a broken response.
  if ((result.values.fold(0.0, (a, b) => a + b) - 1).abs() > 0.01) {
    _invalid('Probabilities do not sum to one');
  }
  return Map.unmodifiable(result);
}

int? _tokens(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 0) _invalid('Invalid token count');
  return value;
}

bool _jsonEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _jsonEqual(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _jsonEqual(a[i], b[i]));
  }
  return a == b;
}
