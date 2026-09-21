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

/// Executes local rules without a model, token budget or network request.
class LocalExecutor implements ClassificationExecutor {
  const LocalExecutor();

  @override
  Object get configuration => const {'kind': 'local', 'revision': 1};

  LocalClassifier<I, O> _classifier<I, O>(ClassificationRequest<I, O> request) {
    final definition = request.definition;
    if (definition is! LocalClassifier<I, O>) {
      throw ArgumentError('A LocalClassifier is required');
    }
    return definition;
  }

  @override
  int estimate<I, O>(ClassificationRequest<I, O> request) {
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
