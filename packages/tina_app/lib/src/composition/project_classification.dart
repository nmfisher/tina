import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:tina_engine/tina_engine.dart';

import '../classification/file_classification_store.dart';
import '../classification/extension_classifier.dart';
import '../classification/index_options.dart';
import '../classification/project_classifiers.dart';
import '../classification/repository_classification_source.dart';
import '../classification/repository_text_source.dart';
import '../classification/project_classification_workflow.dart';
import 'app_composition.dart';
import '../exploration/metered_judgment_service.dart';

/// Both language implementations share source preparation, tree merging,
/// cancellation and persistence. Only JEV needs a judgment service.
Future<ProjectClassificationReport> runProjectClassification(
  AppComposition app, {
  LanguageMethod method = IndexOptions.defaultMethod,
  JudgmentService? judgments,
  JudgmentRequestBudget? requestBudget,
  Object? serviceIdentity,
  SpendLedger? spendLedger,
  String mode = '',
  RepositoryProjection projection = RepositoryProjection.filenames,
  Future<void>? cancelSignal,
  void Function(String)? onProgress,
}) async {
  if (!const ['', 'status', 'refresh'].contains(mode))
    throw ArgumentError(IndexOptions.usage);
  if (method == LanguageMethod.jev &&
      (judgments == null || requestBudget == null || serviceIdentity == null)) {
    throw ArgumentError(
      'JEV classification requires a judgment service and budget',
    );
  }
  if (method == LanguageMethod.extensions &&
      projection != RepositoryProjection.filenames) {
    throw ArgumentError(
      'Extension classification requires the filename projection',
    );
  }
  final root = app.pipeline.tools.projectRoot;
  // Limits come from the classifier transport, never the conversation model.
  final budget = method == LanguageMethod.extensions
      ? ClassificationBudget()
      : ClassificationBudget(
          contextTokens: requestBudget!.maxInputTokens + 2048,
          outputTokens: 1024,
          safetyTokens: 1024,
          maxInputTokens: requestBudget.maxInputTokens,
        );
  final stop = JudgmentCancellation();
  var finished = false;
  cancelSignal?.then(
    (_) {
      if (!finished) stop.cancel();
    },
    onError: (Object _) {
      if (!finished) stop.cancel();
    },
  );
  final ledger =
      spendLedger ?? SpendLedger(maxGlobalTokens: 120000, requestsPerMinute: 0);
  final rules = [...app.policy.staticRules, ...app.policy.sessionRules];
  final ClassificationExecutor runner = method == LanguageMethod.extensions
      ? const LocalExecutor()
      : JudgmentExecutor(
          service: MeteredJudgmentService(
            inner: judgments!,
            ledger: ledger,
            budget: requestBudget!,
            outputTokenAllowance: 1024,
            pauseGate: app.pauseGate,
          ),
          budget: requestBudget,
          identity: {
            'service': serviceIdentity,
            'policy': rules.map((r) => r.toJson()).toList(),
          },
        );
  onProgress?.call(
    'Language classifier: ${method == LanguageMethod.extensions ? 'extensions (local)' : requestBudget!.model}',
  );
  final local = method == LanguageMethod.extensions
      ? SingleRequestPlan(extensionClassifier())
      : languagePlan();
  try {
    final source = RepositoryTextSource(
      projection: projection,
      reader: RepositoryEvidenceReader(
        root: root,
        sandbox: SandboxedFileSystem(
          const IoFileSystem(),
          projectRoot: root,
          tinaDir: tinaDirFromEnv(app.environment.env),
        ),
        policy: PermissionPolicy(mode: PermissionMode.readAll, rules: rules),
      ),
    );
    return await ClassificationOrchestrator(
      store: FileClassificationStore(root),
      executor: runner,
      budget: budget,
      concurrency: 4,
      maxCalls: method == LanguageMethod.extensions ? 20000 : 256,
    ).run(
      (session) => classifyProject(session, source, local: local),
      refresh: mode == 'refresh',
      restoreOnly: mode == 'status',
      cancellation: stop,
      onProgress: onProgress,
    );
  } finally {
    finished = true;
  }
}

String classificationReportText(ProjectClassificationReport report) {
  final lines = <String>[
    'Classification ${report.cancelled
            ? 'cancelled'
            : report.failures.isEmpty
            ? 'complete'
            : 'incomplete'}: '
        '${report.executed} classifier calls, ${report.restored} classifications restored, ${report.reusedRequests} request checkpoints reused.',
  ];
  for (final entry in report.records.entries) {
    final result = entry.value.result;
    lines.add(
      '${entry.key}: ${result.value?.labels.map((l) => l.value).join(', ') ?? result.outcome.name}',
    );
  }
  for (final entry in report.failures.entries) {
    lines.add('${entry.key}: ${entry.value}');
  }
  return '${lines.join('\n')}\n';
}
