import 'package:classifier/classification.dart';

import 'repository_evidence.dart';

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

class ProjectScopes {
  final List<String> paths;
  ProjectScopes(Iterable<String> paths) : paths = List.unmodifiable(paths) {
    if (this.paths.length > 255 ||
        this.paths.toSet().length != this.paths.length ||
        this.paths.any((p) => !validProjectPath(p, root: false)))
      throw const FormatException('Invalid project scopes');
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
final projectScopesContract = DataContract<ProjectScopes>(
  id: 'tina.project_scopes',
  schema: {
    'type': 'object',
    'properties': {
      'paths': {
        'type': 'array',
        'maxItems': 255,
        'items': {'type': 'string'},
      },
    },
    'required': ['paths'],
    'additionalProperties': false,
  },
  encode: (v) => {'paths': v.paths},
  decode: (v) => ProjectScopes((jsonObject(v)['paths'] as List).cast<String>()),
);

class ProjectClassifier {
  final String id;
  final List<String> requires;
  final ClassifierDefinition<TextEvidence, ProjectLabels> definition;
  ProjectClassifier(this.id, String instructions, {this.requires = const []})
    : definition = ClassifierDefinition(
        id: id,
        agentType: '${id}_classifier',
        instructions: instructions,
        input: textEvidenceContract,
        output: projectLabelsContract,
        validateValue: (value, evidence) {
          if (value.labels.any(
            (l) => l.evidence.any((id) => !evidence.contains(id)),
          )) {
            throw const FormatException(
              'Labels must cite the submitted evidence',
            );
          }
        },
      );
}

final scopeClassifier = ClassifierDefinition<TextEvidence, ProjectScopes>(
  id: 'scopes',
  agentType: 'scope_classifier',
  input: textEvidenceContract,
  output: projectScopesContract,
  instructions:
      'Discover independently meaningful packages, applications, services and libraries from the supplied evidence. '
      'Return repository-relative directory paths in paths, excluding the implicit root. '
      'Do not create scopes for ordinary source folders, generated code, fixtures or vendored dependencies. '
      'A repository without nested packages has an empty paths list. Use unknown if the supplied evidence cannot establish boundaries.',
);
final projectClassifiers = <ProjectClassifier>[
  ProjectClassifier(
    'language',
    'Identify all programming languages used by this scope. '
        'Distinguish source languages from dependency implementation languages; exclude generated and vendored code.',
  ),
  ProjectClassifier(
    'framework',
    'Identify application/library frameworks used by this scope. '
        'Use dependency, configuration and source evidence; a language alone does not establish a framework.',
    requires: ['language'],
  ),
  ProjectClassifier(
    'build_system',
    'Identify build and package-management systems configured for this scope from supplied evidence.',
    requires: ['language'],
  ),
  ProjectClassifier(
    'test_system',
    'Identify test frameworks and runners configured for this scope. Do not claim a passing test baseline.',
    requires: ['framework', 'build_system'],
  ),
  ProjectClassifier(
    'target_platform',
    'Identify actually configured target platforms, such as android, ios, web, linux, macos, windows, server or embedded. '
        'A framework supporting a platform does not establish that this project targets it.',
    requires: ['framework', 'build_system'],
  ),
];

/// Aggregation is application policy. In particular, targets and frameworks are
/// not inferred from language alone and unknown chunks do not prove absence.
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
