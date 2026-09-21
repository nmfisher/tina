import 'package:classifier/classification.dart';

import 'project_classifiers.dart';
import 'technology_classifiers.dart';

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

/// Language findings select framework candidates per directory. Tooling is
/// independent. All dimensions share the writer, budgets and request cache.
Future<ProjectClassificationReport> classifyProject(
  ClassificationSession session,
  TreeSource<TextEvidence> source, {
  ClassificationPlan<TextEvidence, ProjectLabels>? local,
  TreeSource<TextEvidence>? detailsSource,
  String? detailsError,
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
    void collect(String kind, TreeReport<ProjectLabels> report) {
      records.addAll({
        for (final e in report.records.entries) '${e.key}::$kind': e.value,
      });
      failures.addAll({
        for (final e in report.failures.entries) '${e.key}::$kind': e.value,
      });
    }

    collect('language', result);
    final keys = plan.keys(tree);
    if (detailsSource != null) {
      final framework = TreePlan<TextEvidence, ProjectLabels>(
        id: 'framework',
        output: projectLabelsContract,
        local: (node) {
          final languages = result.records[node.key];
          return TechnologyPlan(
            frameworkClassifier(
              languages?.coverage.complete == true
                  ? languages?.result.value?.labels.map((l) => l.value) ??
                        const []
                  : const [],
            ),
          );
        },
        merge: (_) => LabelMerge(),
      );
      final tools = TreePlan<TextEvidence, ProjectLabels>(
        id: 'tooling',
        output: projectLabelsContract,
        local: (_) => TechnologyPlan(toolingClassifier),
        merge: (_) => LabelMerge(),
      );
      keys.addAll(framework.keys(tree));
      keys.addAll(tools.keys(tree));
      final reports = await Future.wait([
        session.runTree(
          source: detailsSource,
          request: request,
          tree: tree,
          plan: framework,
          upstream: {
            for (final e in result.records.entries)
              e.key: {'language': e.value.dependency},
          },
          blocked: result.failures.keys.toSet(),
        ),
        session.runTree(
          source: detailsSource,
          request: request,
          tree: tree,
          plan: tools,
        ),
      ]);
      collect('framework', reports[0]);
      collect('tooling', reports[1]);
      // A prerequisite or another dimension may change while a request runs.
      await session.checkTree(
        source,
        tree,
        result.local.keys.map((key) => plan.localKey(tree.nodes[key]!)),
      );
      await session.checkTree(detailsSource, tree, [
        for (final key in reports[0].local.keys)
          framework.localKey(tree.nodes[key]!),
        for (final key in reports[1].local.keys)
          tools.localKey(tree.nodes[key]!),
      ]);
    } else if (detailsError != null) {
      failures['.::framework'] = detailsError;
      failures['.::tooling'] = detailsError;
    }
    // Retire deleted nodes across all dimensions. An unavailable service must
    // not remove previous framework/tooling checkpoints.
    if (!session.cancellation.isCancelled &&
        detailsError == null &&
        !failures.keys.any((key) => key.startsWith('${tree.root}::'))) {
      await session.retainTasks(keys);
    }
  } catch (e) {
    records.clear();
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
