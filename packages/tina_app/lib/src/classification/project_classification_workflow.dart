import 'package:classifier/classification.dart';

import 'project_classifiers.dart';
import 'repository_evidence.dart';

class ProjectClassificationReport {
  final ClassificationRecord<ProjectScopes>? discovery;
  final Map<String, ClassificationRecord<ProjectLabels>> records;
  final Map<String, String> failures;
  final int executed;
  final int restored;
  final int reusedRequests;
  final bool cancelled;
  ProjectClassificationReport(
    this.discovery,
    this.records,
    this.failures,
    this.executed,
    this.restored,
    this.reusedRequests,
    this.cancelled,
  );
}

/// Repository hierarchy and the choice of dimensions belong to the project
/// feature. The package session supplies typed caching and dependency scheduling.
Future<ProjectClassificationReport> classifyProject(
  ClassificationSession session,
  ClassificationSource<TextEvidence> source,
) async {
  ClassificationRecord<ProjectScopes>? discovery;
  final failures = <String, String>{};
  Map<String, ClassificationRecord<ProjectLabels>> records = {};
  try {
    discovery = await session.classify(
      ClassificationTask(
        key: '.::scopes',
        request: SourceRequest('.'),
        source: source,
        plan: projectClassificationPlan(scopeClassifier),
      ),
    );
    final found = discovery.result.value;
    if (found == null) {
      failures['.::scopes'] = 'Project boundaries remain unknown';
    } else {
      final scopes = classificationScopes(found.paths);
      final nodes = <ClassificationNode<TextEvidence, ProjectLabels>>[
        for (final scope in scopes)
          for (final classifier in projectClassifiers)
            ClassificationNode(
              '${scope.path}::${classifier.id}',
              requires: [
                for (final dependency in classifier.requires)
                  '${scope.path}::$dependency',
              ],
              build: (_) => ClassificationTask(
                key: '${scope.path}::${classifier.id}',
                request: SourceRequest(
                  scope.path,
                  parameters: {
                    'parent': scope.parent,
                    'excluded_scopes':
                        scopes
                            .where(
                              (s) =>
                                  s.path != scope.path &&
                                  insideScope(s.path, scope.path),
                            )
                            .map((s) => s.path)
                            .toList()
                          ..sort(),
                  },
                ),
                source: source,
                plan: projectClassificationPlan(classifier.definition),
              ),
            ),
      ];
      if (discovery.coverage.complete)
        await session.retainTasks({'.::scopes', ...nodes.map((n) => n.key)});
      else
        failures['.::scopes'] = discovery.coverage.gaps.join(' ');
      final result = await session.runGraph(nodes);
      records = result.records;
      failures.addAll(result.failures);
    }
  } catch (e) {
    failures['.::scopes'] = session.cancellation.isCancelled
        ? 'Cancelled'
        : '$e';
  }
  for (final e in records.entries) {
    if (!e.value.coverage.complete)
      failures[e.key] = e.value.coverage.gaps.join(' ');
  }
  return ProjectClassificationReport(
    discovery,
    Map.unmodifiable(records),
    Map.unmodifiable(failures),
    session.executed,
    session.restored,
    session.reusedRequests,
    session.cancellation.isCancelled,
  );
}
