import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:tina_engine/tina_engine.dart';

import '../classification/classification_agent_runner.dart';
import '../classification/file_classification_store.dart';
import '../classification/repository_classification_source.dart';
import '../classification/repository_text_source.dart';
import '../classification/project_classification_workflow.dart';
import 'app_composition.dart';
import 'provider_resolution.dart';

/// One command invocation owns its local limits; runtime providers retain the
/// application's metering, rate limit and pause behavior. Restore builds none.
Future<ProjectClassificationReport> runProjectClassification(
  AppComposition app, {
  String mode = '',
  RepositoryProjection projection = RepositoryProjection.filenamesAndContents,
  Future<void>? cancelSignal,
  void Function(String)? onProgress,
}) async {
  if (!const ['', 'status', 'refresh'].contains(mode))
    throw ArgumentError('Usage: /index [status|refresh]');
  final root = app.pipeline.tools.projectRoot;
  final config = app.config;
  final model = app.registry.findModel('${config.provider}/${config.model}');
  final contextWindow = (model?.contextWindow ?? 0) > 0
      ? model!.contextWindow
      : 32768;
  final outputCaps = [
    4096,
    contextWindow ~/ 4,
    if (config.maxTokens > 0) config.maxTokens,
    if ((model?.maxOutput ?? 0) > 0) model!.maxOutput!,
  ];
  outputCaps.sort();
  final budget = ClassificationBudget(
    contextTokens: contextWindow,
    outputTokens: outputCaps.first,
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
  final ledger = SpendLedger(maxGlobalTokens: 120000, requestsPerMinute: 0);
  final rules = [...app.policy.staticRules, ...app.policy.sessionRules];
  final runner = EngineClassificationExecutor(
    configuration: {
      'adapter_revision': 2, 'provider': config.provider, 'model': config.model,
      // Endpoint is configuration, but store only its digest (URLs may contain credentials).
      'endpoint': canonicalFingerprint(config.baseUrl),
      'reasoning_effort': config.reasoningEffort,
      'max_tokens': config.maxTokens,
      'policy': rules.map((r) => r.toJson()).toList(),
      'max_steps': 3,
      'run_tokens': 120000,
    },
    createProvider: (outputLimit) => MeteringProvider(
      buildResolved(
        app.providers,
        config,
        '${config.provider}/${config.model}',
        maxTokensOverride: outputLimit,
        apiKeyOverride: config.apiKey,
        baseUrlOverride: config.baseUrl,
      ),
      ledger,
    ),
    driverFactory:
        app.scheduler.driverFactory ?? const DefaultAgentDriverFactory(),
    policy: app.policy,
    pauseGate: app.pauseGate,
  );
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
    ).run(
      (session) => classifyProject(session, source),
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
        '${report.executed} requests run, ${report.restored} classifications restored, ${report.reusedRequests} request checkpoints reused.',
  ];
  if (report.discovery != null) {
    lines.add(
      '.::scopes: ${report.discovery!.result.value?.paths.join(', ') ?? report.discovery!.result.outcome.name}',
    );
  }
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
