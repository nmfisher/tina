import 'package:attractor/attractor.dart'
    show PipelineEventListener, StageStatus;
import 'package:classifier/classification.dart';

import '../workflows/classify_engine.dart';
import '../workflows/classify_handler.dart';
import '../workflows/classify_program.dart';
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
///
/// The stages run as a classifier program through the attractor engine
/// (docs/proposals/hierarchical_classifiers.md): the `language` stage first,
/// then the `details` stage (framework + tooling in one `Future.wait`), sharing
/// this invocation's tree/plan/result state. The default program sequences them
/// start → language → details → exit; a workspace program can reroute (skip or
/// gate stages) without changing this code. Checkpoint reuse is unaffected by
/// the engine: the same `session.runTree` calls produce the same plan ids and
/// evidence keys as the pre-program implementation.
///
/// Stage exceptions are remembered and rethrown for the engine's recording
/// policy; the report assembly below then reproduces the pre-program
/// try/catch semantics (clear records, fail the report under `.`).
Future<ProjectClassificationReport> classifyProject(
  ClassificationSession session,
  TreeSource<TextEvidence> source, {
  ClassificationPlan<TextEvidence, ProjectLabels>? local,
  TreeSource<TextEvidence>? detailsSource,
  String? detailsError,
  ClassifyProgram? program,
  Future<void>? cancelSignal,
  PipelineEventListener? onEvent,
}) async {
  final failures = <String, String>{};
  final records = <String, ClassificationRecord<ProjectLabels>>{};

  // Shared stage state: `details` consumes what `language` produced. A
  // program that runs `details` without `language` fails on the late read and
  // reports it like any other stage error.
  late final SourceRequest request;
  late final TreeSnapshot tree;
  late final TreePlan<TextEvidence, ProjectLabels> plan;
  late final TreeReport<ProjectLabels> result;
  var keys = <String>{};
  Object? firstError;

  void collect(String kind, TreeReport<ProjectLabels> report) {
    records.addAll({
      for (final e in report.records.entries) '${e.key}::$kind': e.value,
    });
    failures.addAll({
      for (final e in report.failures.entries) '${e.key}::$kind': e.value,
    });
  }

  // Stage status + context keys per decision 2 of the proposal (amended:
  // task failures inside an attempted stage map to partial_success even when
  // zero records classified — downstream stages may be independently valuable,
  // e.g. tooling is local — while a stage that could not attempt its work
  // (details prerequisites unavailable) maps to fail and ends the run).
  var stagesOk = 0;
  var stagesFailed = 0;
  ClassifyStageResult stageResult(
    String stage,
    List<String> kinds, {
    required bool attempted,
  }) {
    bool isStageKey(String key) => kinds.any((k) => key.endsWith('::$k'));
    final stageFailureKeys = failures.keys.where(isStageKey).toList();
    final stageRecords = [
      for (final e in records.entries)
        if (isStageKey(e.key)) e,
    ];
    var classified = 0;
    var incomplete = 0;
    final labelNames = <String>{};
    for (final e in stageRecords) {
      if (!e.value.coverage.complete) incomplete++;
      final value = e.value.result.value;
      if (value == null) continue;
      classified++;
      for (final l in value.labels) labelNames.add(l.value);
    }
    // Decision 2 verbatim: fail requires an actual failure/incomplete record —
    // a settled value-less record (not applicable) with complete coverage is
    // not a failure and must not block the details stage.
    final failed = stageFailureKeys.isNotEmpty || incomplete > 0;
    final status = !failed
        ? StageStatus.success
        : attempted
        ? StageStatus.partialSuccess
        : StageStatus.fail;
    if (status == StageStatus.fail) {
      stagesFailed++;
    } else {
      stagesOk++;
    }
    return ClassifyStageResult(
      status: status,
      // Flat boolean/count keys for stock `Condition` edge routing (decision
      // 1): label.* capped at the 64-label ProjectLabels ceiling.
      contextUpdates: <String, String>{
        'outcome.classified': '${classified > 0}',
        'outcome.unknown': '${classified == 0 && stageRecords.isNotEmpty}',
        'coverage.complete':
            '${stageRecords.isNotEmpty && incomplete == 0 && stageFailureKeys.isEmpty}',
        'stages_ok': '$stagesOk',
        'stages_failed': '$stagesFailed',
        for (final name in labelNames.take(64)) 'label.$name': 'true',
      },
      notes:
          '$stage: $classified classified, ${stageFailureKeys.length} failed',
      failureReason: status != StageStatus.fail
          ? ''
          : stageFailureKeys.isNotEmpty
          ? stageFailureKeys.map((k) => failures[k] ?? '').join(' ')
          : '$stage produced no classifications',
    );
  }

  Future<ClassifyStageResult> runStage({
    required String stage,
    Future<void>? cancelSignal,
  }) async {
    try {
      switch (stage) {
        case 'language':
          request = SourceRequest('.');
          tree = await session.readTree(source, request);
          plan = languageTreePlan(local: local);
          result = await session.runTree(
            source: source,
            request: request,
            tree: tree,
            plan: plan,
          );
          collect('language', result);
          keys = plan.keys(tree);
          return stageResult('language', const ['language'], attempted: true);
        case 'details':
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
            // A prerequisite or another dimension may change while a request
            // runs.
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
          // Retire deleted nodes across all dimensions. An unavailable service
          // must not remove previous framework/tooling checkpoints.
          if (!session.cancellation.isCancelled &&
              detailsError == null &&
              !failures.keys.any((key) => key.startsWith('${tree.root}::'))) {
            await session.retainTasks(keys);
          }
          return stageResult('details', const [
            'framework',
            'tooling',
          ], attempted: detailsSource != null);
        default:
          return ClassifyStageResult(
            status: StageStatus.fail,
            failureReason: 'unknown classify stage "$stage"',
          );
      }
    } catch (e) {
      firstError = e;
      rethrow;
    }
  }

  // A failed stage takes no unconditional edge, so with the built-in program a
  // hard language failure ends the run before `details` — the pre-program
  // catch-all. The engine outcome itself is not part of the report; the
  // assembly below derives it from what the stages recorded.
  await runClassifyProgram(
    program: program ?? builtinIndexProgram(),
    runStage: runStage,
    cancelSignal: cancelSignal,
    onEvent: onEvent,
  );

  if (firstError != null) {
    records.clear();
    failures['.'] = session.cancellation.isCancelled
        ? 'Cancelled'
        : '$firstError';
  }
  for (final entry in records.entries) {
    if (!entry.value.coverage.complete) {
      failures[entry.key] = entry.value.coverage.gaps.join(' ');
    }
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
