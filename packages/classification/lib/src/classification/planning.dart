import '../shared/range_packer.dart';
import 'definitions.dart';
import 'evidence.dart';
import 'models.dart';

class ClassificationBudget {
  final int contextTokens;
  final int outputTokens;
  final int safetyTokens;
  final int maxInputTokens;
  final int maxChunks;
  final int maxReductionRounds;
  ClassificationBudget({
    this.contextTokens = 32768,
    this.outputTokens = 4096,
    this.safetyTokens = 1024,
    this.maxInputTokens = 12000,
    this.maxChunks = 256,
    this.maxReductionRounds = 16,
  }) {
    if (contextTokens <= outputTokens + safetyTokens ||
        outputTokens < 1 ||
        safetyTokens < 0 ||
        maxInputTokens < 1 ||
        maxChunks < 1 ||
        maxReductionRounds < 1)
      throw ArgumentError('Invalid classification budget');
  }
  int get inputLimit =>
      maxInputTokens < contextTokens - outputTokens - safetyTokens
      ? maxInputTokens
      : contextTokens - outputTokens - safetyTokens;
  Map<String, Object?> get identity => {
    'context_tokens': contextTokens,
    'output_tokens': outputTokens,
    'safety_tokens': safetyTokens,
    'max_input_tokens': maxInputTokens,
    'max_chunks': maxChunks,
    'max_reduction_rounds': maxReductionRounds,
  };
}

/// The dispatcher handles metering, cancellation, checkpointing and per-request
/// limits. Plans contain only typed request construction and reduction policy.
abstract interface class ClassificationDispatcher {
  ClassificationBudget get budget;
  bool fits<I, O>(ClassificationRequest<I, O> request);
  Future<ClassificationResult<O>> dispatch<I, O>(
    ClassificationRequest<I, O> request,
  );
}

abstract interface class ClassificationPlan<I, O> {
  Object get identity;
  DataContract<I> get input;
  DataContract<O> get output;
  Future<ClassificationResult<O>> run(
    SourceSnapshot<I> snapshot,
    Map<String, Object?> upstream,
    ClassificationDispatcher dispatcher,
  );
}

class SingleRequestPlan<I, O> implements ClassificationPlan<I, O> {
  final ClassifierDefinition<I, O> classifier;
  SingleRequestPlan(this.classifier);
  @override
  Object get identity => {
    'kind': 'single',
    'revision': 1,
    'classifier': classifier.identity,
  };
  @override
  DataContract<I> get input => classifier.input;
  @override
  DataContract<O> get output => classifier.output;
  @override
  Future<ClassificationResult<O>> run(
    SourceSnapshot<I> snapshot,
    Map<String, Object?> upstream,
    ClassificationDispatcher dispatcher,
  ) => dispatcher.dispatch(
    ClassificationRequest(
      classifier,
      ClassificationInput(
        snapshot.units,
        snapshot.coverage,
        upstream: upstream,
      ),
    ),
  );
}

/// Classify bounded chunks independently and reduce their results in code.
/// The caller owns reduction semantics and includes their version in [reduction].
/// Every dispatched chunk uses the session's shared concurrency and checkpoints.
class ReducedClassificationPlan<I, O> implements ClassificationPlan<I, O> {
  final ClassifierDefinition<I, O> classifier;
  final Object reduction;
  final ClassificationResult<O> Function(
    List<ClassificationResult<O>>,
    InputCoverage,
  )
  reduce;
  ReducedClassificationPlan({
    required this.classifier,
    required Object reduction,
    required this.reduce,
  }) : reduction = freezeJson(reduction)!;
  @override
  Object get identity => {
    'kind': 'code_reduce',
    'revision': 1,
    'classifier': classifier.identity,
    'reduction': reduction,
  };
  @override
  DataContract<I> get input => classifier.input;
  @override
  DataContract<O> get output => classifier.output;
  @override
  Future<ClassificationResult<O>> run(
    SourceSnapshot<I> snapshot,
    Map<String, Object?> upstream,
    ClassificationDispatcher dispatcher,
  ) async {
    ClassificationRequest<I, O> request(List<SourceUnit<I>> units) =>
        ClassificationRequest(
          classifier,
          ClassificationInput(units, snapshot.coverage, upstream: upstream),
        );
    final groups = packClassificationUnits(
      snapshot.units,
      splitter: snapshot.splitter,
      fits: (units) => dispatcher.fits(request(units)),
      maxChunks: dispatcher.budget.maxChunks,
    );
    final results = await Future.wait([
      for (final group in groups) dispatcher.dispatch(request(group)),
    ]);
    final result = reduce(results, snapshot.coverage);
    classifier.validate(
      result,
      ClassificationInput(
        snapshot.units,
        snapshot.coverage,
        upstream: upstream,
      ).evidenceIds.union({for (final value in results) ...value.evidence}),
    );
    return result;
  }
}

class PartialObservation<P> {
  final ClassificationResult<P> result;
  PartialObservation(this.result);
}

DataContract<PartialObservation<P>> partialObservationContract<P>(
  DataContract<P> output,
) => DataContract(
  id: 'classifier.partial.${output.id}',
  revision: output.revision,
  schema: {
    'type': 'object',
    'description': 'A partial classification, not a complete finding',
    'properties': {
      'outcome': {'type': 'string'},
      'value': {
        'anyOf': [
          output.schema,
          {'type': 'null'},
        ],
      },
      'evidence': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'explanation': {'type': 'string'},
    },
    'required': ['outcome', 'value', 'evidence', 'explanation'],
  },
  encode: (v) => v.result.toJson(output),
  decode: (v) => PartialObservation(ClassificationResult.fromJson(v, output)),
);

/// Uses a direct request when it fits. Otherwise maps source chunks to P,
/// combines P with an explicitly supplied classifier, and finalizes into O.
/// No generic label union, confidence average, or truncation is inferred.
class ChunkedClassificationPlan<I, P, O> implements ClassificationPlan<I, O> {
  final ClassifierDefinition<I, O> direct;
  final ClassifierDefinition<I, P> observe;
  final ClassifierDefinition<PartialObservation<P>, P> combine;
  final ClassifierDefinition<PartialObservation<P>, O> finalize;
  ChunkedClassificationPlan({
    required this.direct,
    required this.observe,
    required this.combine,
    required this.finalize,
  }) {
    if (contractFingerprint(direct.input) !=
            contractFingerprint(observe.input) ||
        contractFingerprint(observe.output) !=
            contractFingerprint(combine.output) ||
        contractFingerprint(combine.input) !=
            contractFingerprint(partialObservationContract(observe.output)) ||
        contractFingerprint(combine.input) !=
            contractFingerprint(finalize.input) ||
        contractFingerprint(direct.output) !=
            contractFingerprint(finalize.output)) {
      throw ArgumentError('Incompatible map/reduce contracts');
    }
  }
  @override
  Object get identity => {
    'kind': 'map_reduce',
    'revision': 1,
    'direct': direct.identity,
    'observe': observe.identity,
    'combine': combine.identity,
    'finalize': finalize.identity,
  };
  @override
  DataContract<I> get input => direct.input;
  @override
  DataContract<O> get output => direct.output;

  @override
  Future<ClassificationResult<O>> run(
    SourceSnapshot<I> snapshot,
    Map<String, Object?> upstream,
    ClassificationDispatcher dispatcher,
  ) async {
    final whole = ClassificationRequest(
      direct,
      ClassificationInput(
        snapshot.units,
        snapshot.coverage,
        upstream: upstream,
      ),
    );
    if (dispatcher.fits(whole)) return dispatcher.dispatch(whole);
    final partialCoverage = InputCoverage(
      complete: false,
      gaps: [
        'This request covers only part of the input.',
        ...snapshot.coverage.gaps,
      ],
    );
    ClassificationRequest<I, P> mapRequest(List<SourceUnit<I>> units) =>
        ClassificationRequest(
          observe,
          ClassificationInput(units, partialCoverage, upstream: upstream),
          isFinal: false,
        );
    final groups = packClassificationUnits(
      snapshot.units,
      splitter: snapshot.splitter,
      fits: (units) => dispatcher.fits(mapRequest(units)),
      maxChunks: dispatcher.budget.maxChunks,
    );
    var partials = <SourceUnit<PartialObservation<P>>>[];
    SourceUnit<PartialObservation<P>> partial(
      int round,
      int index,
      ClassificationResult<P> result,
    ) => SourceUnit(
      'observation:$round:$index',
      PartialObservation(result),
      supportingEvidence: result.evidence,
    );
    for (var i = 0; i < groups.length; i++) {
      partials.add(
        partial(0, i, await dispatcher.dispatch(mapRequest(groups[i]))),
      );
    }
    for (
      var round = 1;
      round <= dispatcher.budget.maxReductionRounds;
      round++
    ) {
      final finalRequest = ClassificationRequest(
        finalize,
        ClassificationInput(partials, snapshot.coverage, upstream: upstream),
      );
      if (dispatcher.fits(finalRequest))
        return dispatcher.dispatch(finalRequest);
      ClassificationRequest<PartialObservation<P>, P> reduceRequest(
        List<SourceUnit<PartialObservation<P>>> units,
      ) => ClassificationRequest(
        combine,
        ClassificationInput(units, partialCoverage, upstream: upstream),
        isFinal: false,
      );
      // Partial observations are atomic. If no pair fits, no valid reduction
      // can make progress; return a bounded failure instead of dropping data.
      final batches = packClassificationUnits(
        partials,
        fits: (units) => dispatcher.fits(reduceRequest(units)),
        maxChunks: dispatcher.budget.maxChunks,
      );
      if (batches.length >= partials.length)
        throw const InputTooLargeException();
      final next = <SourceUnit<PartialObservation<P>>>[];
      for (var i = 0; i < batches.length; i++) {
        next.add(
          partial(
            round,
            i,
            await dispatcher.dispatch(reduceRequest(batches[i])),
          ),
        );
      }
      partials = next;
    }
    throw const InputTooLargeException();
  }
}

/// Pack complete units first; split only a unit that cannot fit on its own.
/// Source splitters own legal boundaries; the dispatcher owns request sizing.
List<List<SourceUnit<I>>> packClassificationUnits<I>(
  List<SourceUnit<I>> units, {
  InputSplitter<I>? splitter,
  required bool Function(List<SourceUnit<I>>) fits,
  required int maxChunks,
}) {
  if (!fits([])) throw const InputTooLargeException();
  final expanded = <SourceUnit<I>>[];
  for (final unit in units) {
    if (fits([unit])) {
      expanded.add(unit);
    } else {
      if (splitter == null) throw const InputTooLargeException();
      expanded.addAll(splitter.split(unit, (part) => fits([part]), maxChunks));
    }
  }
  return packInputRanges<List<SourceUnit<I>>>(
    length: expanded.length,
    maxChunks: maxChunks,
    build: (start, end) => expanded.sublist(start, end),
    fits: fits,
    chooseEnd: (_, end) => end,
  ).toList();
}
