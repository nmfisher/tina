import 'package:classifier/classification.dart';

class ProjectLabel {
  final String value;
  final List<String> evidence;
  ProjectLabel(this.value, Iterable<String> evidence)
    : evidence = List.unmodifiable(evidence) {
    if (!RegExp(r'^[a-z0-9][a-z0-9._+\-]{0,79}$').hasMatch(value) ||
        this.evidence.isEmpty) {
      throw const FormatException('Invalid project label');
    }
  }
  Map<String, Object?> toJson() => {'value': value, 'evidence': evidence};
}

class ProjectLabels {
  final List<ProjectLabel> labels;
  ProjectLabels(Iterable<ProjectLabel> labels)
    : labels = List.unmodifiable(labels) {
    if (this.labels.isEmpty ||
        this.labels.length > 64 ||
        this.labels.map((l) => l.value).toSet().length != this.labels.length) {
      throw const FormatException('Invalid project label set');
    }
  }
}

final projectLabelsContract = DataContract<ProjectLabels>(
  id: 'tina.project_labels',
  schema: {
    'type': 'object',
    'properties': {
      'labels': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 64,
        'items': {
          'type': 'object',
          'properties': {
            'value': {'type': 'string'},
            'evidence': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
          'required': ['value', 'evidence'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['labels'],
    'additionalProperties': false,
  },
  encode: (v) => {'labels': v.labels.map((l) => l.toJson()).toList()},
  decode: (v) => ProjectLabels(
    (jsonObject(v)['labels'] as List).map((e) {
      final m = jsonObject(e);
      return ProjectLabel(
        m['value'] as String,
        (m['evidence'] as List).cast<String>(),
      );
    }),
  ),
);
final languageClassifier = ClassifierDefinition<TextEvidence, ProjectLabels>(
  id: 'language',
  agentType: 'language_classifier',
  instructions:
      'Identify all programming languages used by the supplied files. '
      'Distinguish source languages from dependency implementation languages; '
      'exclude generated and vendored code. Classify only from supplied evidence.',
  input: textEvidenceContract,
  output: projectLabelsContract,
  validateValue: (value, evidence) {
    if (value.labels.any(
      (label) => label.evidence.any((id) => !evidence.contains(id)),
    )) {
      throw const FormatException('Labels must cite the submitted evidence');
    }
  },
);

/// Large input sets use the shared chunking plan; unknown chunks do not prove absence.
ClassificationPlan<TextEvidence, O> projectClassificationPlan<O>(
  ClassifierDefinition<TextEvidence, O> direct,
) {
  final partial = partialObservationContract(direct.output);
  ClassifierDefinition<PartialObservation<O>, O> reducer(
    String suffix,
    String stage,
  ) => ClassifierDefinition(
    id: '${direct.id}.$suffix',
    agentType: direct.agentType,
    input: partial,
    output: direct.output,
    instructions:
        '${direct.instructions}\n$stage '
        'Preserve original evidence references, deduplicate findings, and resolve conflicts using evidence. '
        'Unknown observations and incomplete coverage never establish absence. Do not average confidence or invent facts.',
    validateValue: direct.validateValue,
  );
  return ChunkedClassificationPlan<TextEvidence, O, O>(
    direct: direct,
    observe: ClassifierDefinition(
      id: '${direct.id}.observe',
      agentType: direct.agentType,
      input: direct.input,
      output: direct.output,
      instructions:
          '${direct.instructions}\n'
          'This is a partial observation of one input chunk. Report only supported findings; never extrapolate to unseen input.',
      validateValue: direct.validateValue,
    ),
    combine: reducer(
      'combine',
      'Combine these partial observations into a concise partial observation.',
    ),
    finalize: reducer(
      'finalize',
      'Produce the final classification from these observations and the stated coverage.',
    ),
  );
}

/// Language aggregation is a union of classifier findings. This reducer never
/// infers a language from filenames or content; only the classifier does that.
class LanguageMerge
    implements ClassificationPlan<Part<ProjectLabels>, ProjectLabels> {
  LanguageMerge();
  @override
  Object get identity => {'id': 'tina.language_merge', 'revision': 1};
  @override
  DataContract<Part<ProjectLabels>> get input =>
      partContract(projectLabelsContract);
  @override
  DataContract<ProjectLabels> get output => projectLabelsContract;
  @override
  Future<ClassificationResult<ProjectLabels>> run(
    SourceSnapshot<Part<ProjectLabels>> snapshot,
    Map<String, Object?> upstream,
    ClassificationDispatcher dispatcher,
  ) async {
    final parts = snapshot.units.map((unit) => unit.value).toList();
    final labels = <String, Set<String>>{};
    for (final part in parts) {
      for (final label in part.result.value?.labels ?? <ProjectLabel>[]) {
        (labels[label.value] ??= {}).addAll(label.evidence);
      }
    }
    final names = labels.keys.toList()..sort();
    if (names.isNotEmpty) {
      return ClassificationResult(
        outcome: ClassificationOutcome.classified,
        value: ProjectLabels([
          for (final name in names)
            ProjectLabel(name, labels[name]!.toList()..sort()),
        ]),
        evidence: labels.values.expand((ids) => ids).toSet().toList()..sort(),
        explanation:
            'Supported language findings from this node and its children. Unknown parts do not establish absence.',
      );
    }
    final absent =
        parts.isNotEmpty &&
        snapshot.coverage.complete &&
        parts.every(
          (part) => part.result.outcome == ClassificationOutcome.notApplicable,
        );
    return ClassificationResult(
      outcome: absent
          ? ClassificationOutcome.notApplicable
          : ClassificationOutcome.unknown,
      explanation: absent
          ? 'No applicable language findings in any part.'
          : 'No supported language findings; absence is not established.',
    );
  }
}

TreePlan<TextEvidence, ProjectLabels> languageTreePlan() => TreePlan(
  id: 'language',
  output: projectLabelsContract,
  local: (_) => projectClassificationPlan(languageClassifier),
  merge: (_) => LanguageMerge(),
);
