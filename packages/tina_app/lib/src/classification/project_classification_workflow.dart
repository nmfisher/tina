import 'package:classifier/classification.dart';

import 'project_classifiers.dart';

class ProjectClassificationReport {
  final Map<String, ClassificationRecord<ProjectLabels>> records;
  final Map<String, String> failures;
  final int executed;
  final int restored;
  final int reusedRequests;
  final bool cancelled;
  ProjectClassificationReport(
    this.records,
    this.failures,
    this.executed,
    this.restored,
    this.reusedRequests,
    this.cancelled,
  );
}

/// /index classifies only languages. Directory discovery and input collection
/// are source-owned; the classifier supplies findings and parents merge them.
Future<ProjectClassificationReport> classifyProject(
  ClassificationSession session,
  TreeSource<TextEvidence> source, {
  ClassificationPlan<TextEvidence, ProjectLabels>? local,
}) async {
  final failures = <String, String>{};
  final records = <String, ClassificationRecord<ProjectLabels>>{};
  try {
    final request = SourceRequest('.');
    final tree = await session.readTree(source, request);
    final plan = languageTreePlan(local: local);
    final result = await session.runTree(
      source: source,
      request: request,
      tree: tree,
      plan: plan,
    );
    records.addAll({
      for (final entry in result.records.entries)
        '${entry.key}::language': entry.value,
    });
    failures.addAll({
      for (final entry in result.failures.entries)
        '${entry.key}::language': entry.value,
    });
    // Discovery was exhaustive. Retire removed nodes and old project tasks,
    // while retaining immutable request checkpoints for retries.
    if (!session.cancellation.isCancelled &&
        !result.failures.containsKey(tree.root)) {
      await session.retainTasks(plan.keys(tree));
    }
  } catch (e) {
    failures['.'] = session.cancellation.isCancelled ? 'Cancelled' : '$e';
  }
  for (final entry in records.entries) {
    if (!entry.value.coverage.complete)
      failures[entry.key] = entry.value.coverage.gaps.join(' ');
  }
  return ProjectClassificationReport(
    Map.unmodifiable(records),
    Map.unmodifiable(failures),
    session.executed,
    session.restored,
    session.reusedRequests,
    session.cancellation.isCancelled,
  );
}
