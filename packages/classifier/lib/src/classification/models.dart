import 'dart:convert';

import '../shared/fingerprint.dart';

const classificationSchemaVersion = 2;

/// Stable wire identity, schema and codec. Dart runtime type names are never
/// used as persistence identifiers. Bump revision when meaning or encoding changes.
class DataContract<T> {
  final String id;
  final int revision;
  final Map<String, Object?> schema;
  final Object? Function(T) encode;
  final T Function(Object?) decode;
  DataContract({
    required this.id,
    this.revision = 1,
    required Map<String, Object?> schema,
    required this.encode,
    required this.decode,
  }) : schema = freezeJson(schema) as Map<String, Object?> {
    if (id.isEmpty || revision < 1)
      throw ArgumentError('Invalid data contract');
  }
  Map<String, Object?> get identity => {
    'id': id,
    'revision': revision,
    'schema': schema,
  };
}

/// Freeze JSON data at API boundaries so identities cannot change after use.
Object? freezeJson(Object? value) {
  if (value is Map)
    return Map<String, Object?>.unmodifiable({
      for (final e in value.entries) e.key as String: freezeJson(e.value),
    });
  if (value is List) return List<Object?>.unmodifiable(value.map(freezeJson));
  if (value == null ||
      value is String ||
      value is bool ||
      (value is num && value.isFinite))
    return value;
  throw ArgumentError('Expected finite JSON data');
}

Map<String, Object?> jsonObject(Object? value) =>
    Map<String, Object?>.from(value as Map);

class SourceRequest {
  final String subject;
  final Map<String, Object?> parameters;
  SourceRequest(this.subject, {Map<String, Object?> parameters = const {}})
    : parameters = freezeJson(parameters) as Map<String, Object?> {
    if (subject.isEmpty) throw ArgumentError('Empty source subject');
  }
  Map<String, Object?> toJson() => {
    'subject': subject,
    'parameters': parameters,
  };
}

/// An opaque source-owned receipt. Only its source interprets freshness.
class SourceRevision {
  final Map<String, Object?> receipt;
  SourceRevision(Map<String, Object?> receipt)
    : receipt = freezeJson(receipt) as Map<String, Object?>;
}

class InputCoverage {
  final bool complete;
  final List<String> gaps;
  InputCoverage({this.complete = true, Iterable<String> gaps = const []})
    : gaps = List.unmodifiable(gaps) {
    if (complete && this.gaps.isNotEmpty)
      throw ArgumentError('Complete coverage cannot have gaps');
  }
  Map<String, Object?> toJson() => {'complete': complete, 'gaps': gaps};
  factory InputCoverage.fromJson(Object? json) {
    final map = jsonObject(json);
    return InputCoverage(
      complete: map['complete'] as bool,
      gaps: (map['gaps'] as List).cast<String>(),
    );
  }
}

/// An evidence unit has no prescribed source domain. Locations may be record
/// keys, document sections, scalar spans, timestamps, or application metadata.
class SourceUnit<I> {
  final String id;
  final I value;
  final Map<String, Object?> location;
  final List<String> supportingEvidence;
  SourceUnit(
    this.id,
    this.value, {
    Map<String, Object?> location = const {},
    Iterable<String> supportingEvidence = const [],
  }) : location = freezeJson(location) as Map<String, Object?>,
       supportingEvidence = List.unmodifiable(supportingEvidence) {
    if (id.isEmpty) throw ArgumentError('Empty evidence ID');
  }
  Map<String, Object?> toJson(DataContract<I> contract) => {
    'id': id,
    'value': contract.encode(value),
    'location': location,
    'supporting_evidence': supportingEvidence,
  };
}

/// Text is one supported input contract, not the universal raw input type.
/// Meaning distinguishes e.g. a complete document from a filename or summary.
class TextEvidence {
  final String meaning;
  final String text;
  TextEvidence(this.meaning, this.text) {
    if (meaning.isEmpty) throw ArgumentError('Text evidence needs a meaning');
  }
}

final textEvidenceContract = DataContract<TextEvidence>(
  id: 'classifier.text_evidence',
  schema: {
    'type': 'object',
    'properties': {
      'meaning': {'type': 'string'},
      'text': {'type': 'string'},
    },
    'required': ['meaning', 'text'],
    'additionalProperties': false,
  },
  encode: (v) => {'meaning': v.meaning, 'text': v.text},
  decode: (v) {
    final m = jsonObject(v);
    return TextEvidence(m['meaning'] as String, m['text'] as String);
  },
);

enum ClassificationOutcome { classified, unknown, notApplicable }

class ClassificationResult<O> {
  final ClassificationOutcome outcome;
  final O? value;
  final List<String> evidence;
  final String explanation;
  ClassificationResult({
    required this.outcome,
    this.value,
    Iterable<String> evidence = const [],
    required this.explanation,
  }) : evidence = List.unmodifiable(evidence) {
    if ((outcome == ClassificationOutcome.classified) != (value != null) ||
        explanation.trim().isEmpty ||
        explanation.length > 4000 ||
        this.evidence.toSet().length != this.evidence.length) {
      throw const FormatException('Invalid classification result');
    }
  }
  Map<String, Object?> toJson(DataContract<O> contract) => {
    'outcome': outcome.name,
    'value': value == null ? null : contract.encode(value as O),
    'evidence': evidence,
    'explanation': explanation,
  };
  static ClassificationResult<T> fromJson<T>(
    Object? json,
    DataContract<T> contract,
  ) {
    final m = jsonObject(json);
    return ClassificationResult<T>(
      outcome: ClassificationOutcome.values.byName(m['outcome'] as String),
      value: m['value'] == null ? null : contract.decode(m['value']),
      evidence: (m['evidence'] as List).cast<String>(),
      explanation: m['explanation'] as String,
    );
  }
}

class ClassificationRecord<O> {
  final String id;
  final ClassificationResult<O> result;
  final InputCoverage coverage;
  final Map<String, Object?> encodedResult;
  ClassificationRecord(
    this.id,
    this.result,
    this.coverage,
    DataContract<O> contract,
  ) : encodedResult =
          freezeJson(result.toJson(contract)) as Map<String, Object?>;
  Map<String, Object?> get dependency => {
    'id': id,
    'result': encodedResult,
    'coverage': coverage.toJson(),
  };
}

/// JSON request sizes, including non-ASCII text, can be bounded conservatively
/// without coupling the core to a provider tokenizer.
int conservativeTokenEstimate(Object? serializedRequest) =>
    utf8.encode(jsonEncode(serializedRequest)).length;
String contractFingerprint<T>(DataContract<T> contract) =>
    canonicalFingerprint(contract.identity);
