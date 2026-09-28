import '../judgments/service.dart' show JudgmentCancellation;
import 'models.dart';

class ClassifierDefinition<I, O> {
  final String id;
  final int revision;
  final String agentType;
  final int agentRevision;
  final String instructions;
  final DataContract<I> input;
  final DataContract<O> output;
  final void Function(O value, Set<String> availableEvidence)? validateValue;
  ClassifierDefinition({
    required this.id,
    required this.agentType,
    required this.instructions,
    required this.input,
    required this.output,
    this.revision = 1,
    this.agentRevision = 1,
    this.validateValue,
  }) {
    if (id.isEmpty ||
        agentType.isEmpty ||
        instructions.isEmpty ||
        revision < 1 ||
        agentRevision < 1) {
      throw ArgumentError('Invalid classifier definition');
    }
  }
  Map<String, Object?> get identity => {
    'id': id,
    'revision': revision,
    'agent_type': agentType,
    'agent_revision': agentRevision,
    'instructions': instructions,
    'input': input.identity,
    'output': output.identity,
  };

  void validate(ClassificationResult<O> result, Set<String> evidence) {
    if (result.evidence.any((id) => !evidence.contains(id)))
      throw const FormatException('Unobserved evidence reference');
    if (result.value != null) {
      // Round-trip through the output contract before accepting a result.
      output.decode(output.encode(result.value as O));
      validateValue?.call(result.value as O, result.evidence.toSet());
    }
  }

  Map<String, Object?> get resultSchema => {
    'type': 'object',
    'properties': {
      'outcome': {
        'type': 'string',
        'enum': ClassificationOutcome.values.map((v) => v.name).toList(),
      },
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
      'explanation': {'type': 'string', 'maxLength': 4000},
    },
    'required': ['outcome', 'value', 'evidence', 'explanation'],
    'additionalProperties': false,
  };
}

class ClassificationInput<I> {
  final List<SourceUnit<I>> units;
  final InputCoverage coverage;
  final Map<String, Object?> upstream;
  ClassificationInput(
    Iterable<SourceUnit<I>> units,
    this.coverage, {
    Map<String, Object?> upstream = const {},
  }) : units = List.unmodifiable(units),
       upstream = freezeJson(upstream) as Map<String, Object?> {
    if (this.units.map((u) => u.id).toSet().length != this.units.length)
      throw ArgumentError('Duplicate evidence IDs');
  }
  Set<String> get evidenceIds => {
    for (final unit in units) unit.id,
    for (final unit in units) ...unit.supportingEvidence,
    for (final key in upstream.keys) 'upstream:$key',
  };
  Map<String, Object?> toJson(DataContract<I> contract) => {
    'evidence': units.map((u) => u.toJson(contract)).toList(),
    'coverage': coverage.toJson(),
    'upstream': upstream,
  };
}

class ClassificationRequest<I, O> {
  final ClassifierDefinition<I, O> definition;
  final ClassificationInput<I> input;
  final bool isFinal;
  ClassificationRequest(this.definition, this.input, {this.isFinal = true});
  void validate(ClassificationResult<O> result) {
    definition.validate(result, input.evidenceIds);
    if (isFinal &&
        !input.coverage.complete &&
        result.outcome == ClassificationOutcome.notApplicable) {
      throw const FormatException(
        'Incomplete input cannot establish a complete negative classification',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'definition': definition.identity,
    'is_final': isFinal,
    'input': input.toJson(definition.input),
  };
}

/// The adapter owns request serialization/tokenization and model invocation.
/// Estimate must cover the exact initial request: instructions, input, schemas
/// and framing. Retry/history growth must also be bounded by the adapter.
abstract interface class ClassificationExecutor {
  Object get configuration;
  int estimate<I, O>(ClassificationRequest<I, O> request);
  Future<ClassificationResult<O>> execute<I, O>(
    ClassificationRequest<I, O> request,
    JudgmentCancellation cancellation, {
    required int maxInputTokens,
    required int maxOutputTokens,
  });
}
