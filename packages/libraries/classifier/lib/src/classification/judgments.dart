import '../judgments/models.dart';
import '../judgments/request_budget.dart';
import '../judgments/service.dart';
import 'definitions.dart';
import 'models.dart';

/// A typed classification backed by constrained judgments, not a chat turn.
/// [spec] versions the question vocabulary and decoding policy in cache keys.
class JudgmentClassifier<I, O> extends ClassifierDefinition<I, O> {
  final Object spec;
  final JudgmentRequest Function(ClassificationInput<I>) prepare;
  final ClassificationResult<O> Function(
    JudgmentRequest request,
    JudgmentResult result,
    ClassificationInput<I> input,
  )
  decode;
  JudgmentClassifier({
    required super.id,
    super.revision,
    required super.agentType,
    super.agentRevision,
    required super.instructions,
    required super.input,
    required super.output,
    super.validateValue,
    required Object spec,
    required this.prepare,
    required this.decode,
  }) : spec = freezeJson(spec)!;
  @override
  Map<String, Object?> get identity => {...super.identity, 'judgment': spec};
}

/// Reuses the judgment transport and its complete-request estimator. The
/// classification session supplies global concurrency, caching and call limits;
/// no nested batch runner, provider, tool protocol or agent driver is needed.
class JudgmentExecutor implements ClassificationExecutor {
  final JudgmentService service;
  final JudgmentRequestBudget budget;
  @override
  final Object configuration;
  JudgmentExecutor({
    required this.service,
    required this.budget,
    required Object identity,
  }) : configuration = freezeJson({
         'kind': 'judgment',
         'revision': 1,
         'service': identity,
         'model': budget.model,
         'max_input_tokens': budget.maxInputTokens,
         'overhead_tokens': budget.overheadTokens,
       })!;

  JudgmentClassifier<I, O> _classifier<I, O>(
    ClassificationRequest<I, O> request,
  ) {
    final definition = request.definition;
    if (definition is! JudgmentClassifier<I, O>) {
      throw ArgumentError('A JudgmentClassifier is required');
    }
    return definition;
  }

  @override
  int estimate<I, O>(ClassificationRequest<I, O> request) =>
      budget.estimate(_classifier(request).prepare(request.input));

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
    final classifier = _classifier(request);
    final prepared = classifier.prepare(request.input);
    if (budget.check(prepared) > maxInputTokens) {
      throw const JudgmentException(
        JudgmentFailure.requestTooLarge,
        attempted: false,
      );
    }
    final answer = await service.evaluate(prepared, cancellation: cancellation);
    if (cancellation.isCancelled) {
      throw const JudgmentException(JudgmentFailure.cancelled);
    }
    final result = classifier.decode(prepared, answer, request.input);
    request.validate(result);
    return result;
  }
}
