import 'dart:io';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:tina_engine/tina_engine.dart';

import '../classification/sqlite_classification_store.dart';
import '../classification/index_view.dart';
import '../classification/extension_classifier.dart';
import '../classification/index_options.dart';
import '../classification/project_classifiers.dart';
import '../classification/repository_classification_source.dart';
import '../classification/repository_text_source.dart';
import '../classification/project_classification_workflow.dart';
import '../workflows/classify_program.dart';
import 'app_composition.dart';
import '../exploration/metered_judgment_service.dart';

RepositoryEvidenceReader _reader(AppComposition app) =>
    RepositoryEvidenceReader(
      root: app.pipeline.tools.workspaceRoot,
      skipHidden: app.config.indexSkipHidden,
      sandbox: SandboxedFileSystem(
        const IoFileSystem(),
        workspaceRoot: app.pipeline.tools.workspaceRoot,
        tinaDir: tinaDirFromEnv(app.environment.env),
      ),
      policy: PermissionPolicy(
        mode: PermissionMode.readAll,
        rules: [...app.policy.staticRules, ...app.policy.sessionRules],
      ),
    );

Future<IndexView> readProjectIndex(
  AppComposition app, {
  Future<void>? cancelSignal,
  void Function(String)? onProgress,
}) async {
  var cancelled = false;
  cancelSignal?.then(
    (_) => cancelled = true,
    onError: (Object _) => cancelled = true,
  );
  final store = await SqliteClassificationStore.open(
    app.pipeline.tools.workspaceRoot,
    cancelSignal: cancelSignal,
    onProgress: (text) {
      if (!cancelled) onProgress?.call(text);
    },
  );
  try {
    if (cancelled) throw StateError('Index view cancelled');
    final view = await readIndex(store: store);
    if (cancelled) throw StateError('Index view cancelled');
    return view;
  } catch (_) {
    await store.close();
    rethrow;
  }
}

/// Language, framework and tooling results share one persisted directory index.
/// Language may run locally; framework and tooling always use judgments.
Future<ProjectClassificationReport> runProjectClassification(
  AppComposition app, {
  LanguageMethod method = IndexOptions.defaultMethod,
  JudgmentService? judgments,
  JudgmentRequestBudget? requestBudget,
  Object? serviceIdentity,
  SpendLedger? spendLedger,
  String mode = '',
  required Directory? globalWorkflowsDir,
  RepositoryProjection projection = RepositoryProjection.filenames,
  Future<void>? cancelSignal,
  void Function(String)? onProgress,
  void Function(int done, int total)? onTaskProgress,
}) async {
  if (!const ['', 'status', 'refresh'].contains(mode))
    throw ArgumentError(IndexOptions.usage);
  if (method == LanguageMethod.jev &&
      (judgments == null || requestBudget == null || serviceIdentity == null)) {
    throw ArgumentError(
      'JEV classification requires a judgment service and budget',
    );
  }
  final hasJudgments =
      judgments != null && requestBudget != null && serviceIdentity != null;
  if (method == LanguageMethod.extensions &&
      projection != RepositoryProjection.filenames) {
    throw ArgumentError(
      'Extension classification requires the filename projection',
    );
  }
  final root = app.pipeline.tools.workspaceRoot;
  // Program resolution (decision 3): a workspace `.tina/programs` file beats
  // [globalWorkflowsDir]; no file anywhere means the built-in. An invalid
  // file fails fast with its diagnostics — never masked by the fallback.
  final program = await loadIndexProgram(
    workspaceRoot: root,
    globalWorkflowsDir: globalWorkflowsDir,
  );
  if (!program.valid) {
    return ProjectClassificationReport(
      const {},
      {
        'program': 'invalid classify program ${program.origin}:\n'
            '${program.errorsText}',
      },
      0,
      0,
      0,
      false,
    );
  }
  // Limits come from the classifier transport, never the conversation model.
  final budget = !hasJudgments
      ? ClassificationBudget()
      : ClassificationBudget(
          contextTokens: requestBudget.maxInputTokens + 2048,
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
  final runner = LocalExecutor(
    fallback: !hasJudgments
        ? null
        : JudgmentExecutor(
            service: MeteredJudgmentService(
              inner: judgments,
              ledger: ledger,
              budget: requestBudget,
              outputTokenAllowance: 1024,
              pauseGate: app.pauseGate,
            ),
            budget: requestBudget,
            identity: {
              'service': serviceIdentity,
              'policy': rules.map((r) => r.toJson()).toList(),
            },
          ),
  );
  onProgress?.call(
    'Language classifier: ${method == LanguageMethod.extensions ? 'extensions (local)' : requestBudget!.model}',
  );
  final local = method == LanguageMethod.extensions
      ? SingleRequestPlan(extensionClassifier())
      : languagePlan();
  if (hasJudgments) {
    onProgress?.call(
      'Framework and tooling classifiers: ${requestBudget.model}',
    );
  }
  final store = await SqliteClassificationStore.open(
    root,
    create: mode != 'status',
    cancelSignal: cancelSignal,
    onProgress: onProgress,
  );
  try {
    final reader = _reader(app);
    final source = RepositoryTextSource(projection: projection, reader: reader);
    return await ClassificationOrchestrator(
      store: store,
      executor: runner,
      budget: budget,
      concurrency: 4,
      maxCalls: method == LanguageMethod.extensions ? 20000 : 256,
    ).run(
      (session) => classifyProject(
        session,
        source,
        local: local,
        cancelSignal: cancelSignal,
        program: program,
        onEvent: (event) {
          final progress = onProgress;
          if (progress == null) return;
          if (event.kind == 'node_started') {
            progress('Program ${program.name}: stage ${event.nodeId}');
          } else if (event.kind == 'node_failed') {
            progress(
              'Program ${program.name}: stage ${event.nodeId} failed'
              '${event.message == null ? '' : ': ${event.message}'}',
            );
          }
        },
        detailsSource: hasJudgments
            ? RepositoryTextSource(
                reader: reader,
                selectedOnly: true,
                contentNames: {...projectManifestNames, ...toolingConfigNames},
                contentSuffixes: const [
                  '.gradle',
                  '.gradle.kts',
                  '.csproj',
                  '.fsproj',
                  '.yaml',
                  '.yml',
                  '.tf',
                  '.tf.json',
                ],
              )
            : null,
        detailsError: hasJudgments
            ? null
            : 'Configure Typesafe in /settings or set TYPESAFE_API_KEY '
                  'to classify frameworks and tooling.',
      ),
      refresh: mode == 'refresh',
      restoreOnly: mode == 'status',
      cancellation: stop,
      onProgress: onProgress,
      onTaskProgress: onTaskProgress,
    );
  } finally {
    finished = true;
    await store.close();
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
