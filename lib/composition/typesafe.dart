import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/tina_app.dart';

/// File credential wins over environment, consistently with chat credentials.
/// An absent/cleared file credential falls back to TYPESAFE_API_KEY.
TypeSafeConfig? resolveTypeSafeConfig(
  UserConfig config,
  Map<String, String> env,
) {
  final stored = config.typeSafe?.apiKey;
  final key = stored != null && stored.trim().isNotEmpty
      ? stored
      : env['TYPESAFE_API_KEY'];
  if (key == null || key.trim().isEmpty) return null;
  return TypeSafeConfig(
    apiKey: key,
    model: config.typeSafe?.model ?? 'jev-latest',
  );
}

/// Reads the latest saved settings at construction, without registering a chat
/// provider. The consumer owns and closes the returned service. No HTTP request
/// is made until evaluate is called; saving credentials is not authentication.
TypeSafeJudgmentService? createConfiguredTypeSafeService({
  required Map<String, String> env,
  Directory? tinaDir,
  http.Client Function()? clientFactory,
}) {
  final config = resolveTypeSafeConfig(
    loadUserConfig(env: env, tinaDir: tinaDir),
    env,
  );
  if (config == null) return null;
  return TypeSafeJudgmentService(config: config, clientFactory: clientFactory);
}

/// One shared tool per frontend, with fresh credentials and transport per run.
/// Normal ToolOutputEvents carry progress; the turn's cancel signal tears down
/// the scan and requests. No separate background job can outlive the turn.
ExploreProjectTool createConfiguredExplorationTool({
  required String projectRoot,
  required Map<String, String> env,
  required SpendLedger spendLedger,
  PauseGate? pauseGate,
  Directory? tinaDir,
  http.Client Function()? clientFactory,
  ProjectEvidenceSource? evidenceSource,
}) => ExploreProjectTool(
  open: () {
    final settings = loadUserConfig(env: env, tinaDir: tinaDir);
    final config = resolveTypeSafeConfig(settings, env);
    if (config == null) return null;
    final service = TypeSafeJudgmentService(
      config: config,
      clientFactory: clientFactory,
    );
    try {
      const outputTokenAllowance = 1024;
      final metered = MeteredJudgmentService(
        inner: service,
        ledger: spendLedger,
        pauseGate: pauseGate,
        budget: service.config.requestBudget,
        outputTokenAllowance: outputTokenAllowance,
      );
      final source =
          evidenceSource ??
          RepositoryEvidenceSource(
            root: projectRoot,
            sandbox: SandboxedFileSystem(
              const IoFileSystem(),
              projectRoot: projectRoot,
              tinaDir: tinaDir ?? tinaDirFromEnv(env),
            ),
          );
      final timeout = Duration(
        seconds: settings.typeSafe?.explorationTimeoutSeconds ?? 120,
      );
      final workflow = ExplorationWorkflow(
        timeout: timeout,
        source: source,
        cache: FileExplorationCache(projectRoot),
        cacheEndpoint: config.endpoint.toString(),

        selectionThreshold:
            settings.typeSafe?.explorationSelectionThreshold ?? 0.9,
        metadataRunner: JudgmentBatchRunner(
          service: metered,
          budget: service.config.requestBudget,
          limits: JudgmentBatchLimits(
            concurrency: 4,
            maxRequests: 5000,
            maxChargedTokens:
                settings.typeSafe?.explorationMetadataTokenBudget ?? 60000,
            timeout: timeout,
            outputTokenAllowance: outputTokenAllowance,
          ),
        ),
        runner: JudgmentBatchRunner(
          service: metered,
          budget: service.config.requestBudget,
          limits: JudgmentBatchLimits(
            concurrency: 4,
            maxRequests: 5000,
            maxChargedTokens:
                settings.typeSafe?.explorationTokenBudget ?? 120000,
            timeout: timeout,
            outputTokenAllowance: outputTokenAllowance,
          ),
        ),
      );
      return ExplorationLease(workflow, service.close);
    } catch (_) {
      service.close();
      rethrow;
    }
  },
);
