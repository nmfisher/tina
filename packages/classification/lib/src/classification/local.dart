import '../judgments/service.dart';
import 'definitions.dart';
import 'models.dart';

/// A deterministic classifier implemented in code. Rules and options belong in
/// [spec] so changes invalidate the same caches used by model classifiers.
class LocalClassifier<I, O> extends ClassifierDefinition<I, O> {
  final Object spec;
  final ClassificationResult<O> Function(ClassificationInput<I>) classify;

  LocalClassifier({
    required super.id,
    super.revision,
    required super.agentType,
    super.agentRevision,
    required super.instructions,
    required super.input,
    required super.output,
    super.validateValue,
    required Object spec,
    required this.classify,
  }) : spec = freezeJson(spec)!;

  @override
  Map<String, Object?> get identity => {...super.identity, 'local': spec};
}

/// Executes local rules without model calls. An optional fallback handles other
/// classifier types in the same session, sharing its cache and cancellation.
class LocalExecutor implements ClassificationExecutor {
  final ClassificationExecutor? fallback;
  const LocalExecutor({this.fallback});

  @override
  Object get configuration => {
    'kind': 'local',
    'revision': 1,
    if (fallback != null) 'fallback': fallback!.configuration,
  };

  LocalClassifier<I, O> _classifier<I, O>(ClassificationRequest<I, O> request) {
    final definition = request.definition;
    if (definition is! LocalClassifier<I, O>) {
      throw ArgumentError('A LocalClassifier is required');
    }
    return definition;
  }

  @override
  int estimate<I, O>(ClassificationRequest<I, O> request) {
    if (request.definition is! LocalClassifier<I, O> && fallback != null) {
      return fallback!.estimate(request);
    }
    _classifier(request);
    return 0;
  }

  @override
  Future<ClassificationResult<O>> execute<I, O>(
    ClassificationRequest<I, O> request,
    JudgmentCancellation cancellation, {
    required int maxInputTokens,
    required int maxOutputTokens,
  }) async {
    if (request.definition is! LocalClassifier<I, O> && fallback != null) {
      return fallback!.execute(
        request,
        cancellation,
        maxInputTokens: maxInputTokens,
        maxOutputTokens: maxOutputTokens,
      );
    }
    if (cancellation.isCancelled) {
      throw const JudgmentException(
        JudgmentFailure.cancelled,
        attempted: false,
      );
    }
    final result = _classifier(request).classify(request.input);
    if (cancellation.isCancelled) {
      throw const JudgmentException(
        JudgmentFailure.cancelled,
        attempted: false,
      );
    }
    request.validate(result);
    return result;
  }
}
