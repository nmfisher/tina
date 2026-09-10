import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/environment/environment_prompt.dart';
import 'package:tina_app/src/platform/environment.dart';
import 'package:tina_app/src/composition/agent_composition.dart';
import 'package:tina_app/src/composition/runtime_plugins.dart';
import 'package:tina_app/src/composition/runtime_resources.dart';

import 'package:tina_app/src/execution/project_execution.dart';

class ExecutionRuntime implements ProjectExecution {
  final RuntimeConfig config;
  final Environment environment;
  @override
  final LlmProviderFactory providers;
  @override
  final PermissionPolicy policy;
  @override
  final AgentPipeline pipeline;
  @override
  final SubAgentScheduler scheduler;
  @override
  final SpendLedger spendLedger;
  final PauseGate pauseGate;
  final PermissionClassifier? classifier;
  final RuntimeResources resources;

  /// The runtime's own plugin scope (ledger, provider factory, and — when the
  /// runtime owns the project — the built capabilities and tool scope).
  final PluginScope pluginScope;
  ExecutionRuntime({
    required this.config,
    required this.environment,
    required this.providers,
    required this.policy,
    required this.pipeline,
    required this.scheduler,
    required this.spendLedger,
    required this.pauseGate,
    required this.classifier,
    required this.resources,
    required this.pluginScope,
  });
  @override
  Future<void> dispose() => resources.dispose();
  @override
  LlmProvider buildStartupProvider() {
    if (resources.isClosing) throw StateError('Runtime is closing');
    return providers.build(
      '${config.provider}/${config.model}',
      apiKeyOverride: config.apiKey,
      baseUrlOverride: config.baseUrl,
      maxTokens: config.maxTokens,
      streamIdleTimeout: config.streamIdleTimeout,
      requestTimeout: config.requestTimeout,
    );
  }
}

/// Owns providers, classifier and scheduler; borrows the catalog and optional
/// same-project tool/prompt scopes. No session store or resume lookup is created.
Future<ExecutionRuntime> buildExecutionRuntime({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  Environment? environment,
  String? projectRoot,
  ProjectToolScope? toolScope,
  PromptContext? promptContext,
  bool? loadProjectContext,
}) async {
  final env = environment ?? const PlatformEnvironment();
  final root = p.normalize(
    p.absolute(
      projectRoot ??
          toolScope?.projectRoot ??
          promptContext?.projectRoot ??
          Directory.current.path,
    ),
  );
  if (toolScope != null && toolScope.projectRoot != root) {
    throw ArgumentError('toolScope must belong to the requested projectRoot');
  }
  if (promptContext != null &&
      (promptContext.projectRoot != root ||
          (loadProjectContext != null &&
              loadProjectContext != promptContext.loadProjectContext))) {
    throw ArgumentError(
      'promptContext must match the requested project and trust',
    );
  }
  final pauseGate = PauseGate();
  final policy = config.buildPolicy();
  // The two built-in plugins hold the ledger and the provider factory. The
  // ledger is created BEFORE anything can build a provider, so the runtime
  // factory meters every provider built from here on — the startup provider
  // (AppComposition.buildStartupProvider), per-conversation providers, and
  // every sub-agent. (An injected test provider bypasses the factory and so
  // isn't metered, which is fine for fakes.) The ordering is guaranteed by
  // declaration order and by the factory plugin's explicit `requires` edge.
  //
  // The third stage owns the project itself: capabilities, then the tool
  // scope assembled from them (the scope plugin `requires` the capabilities
  // key, which fixes the order). When BORROWING a live same-project scope the
  // stage runs no plugins — the borrowed scope's capabilities stay exactly
  // the ones its owner built.
  final runtime = PluginRuntime(
    name: 'execution',
    plugins: [
      spendLedgerPlugin(config),
      // Decorator contributions mount BEFORE the factory: the factory plugin
      // requires the ProviderDecoratorStage marker (an order-only edge), so
      // every registered decorator contribution exists before the factory
      // builds its policy stack. Empty by default — the factory then wraps
      // metering only, exactly the pre-plugin behavior.
      providerDecoratorsPlugin(const []),
      providerFactoryPlugin(config, registry, pauseGate,
          orderOnDecoratorStage: true),
      if (toolScope == null) ...[
        projectCapabilitiesPlugin(
          projectRoot: root,
          env: env.env,
          sandboxEnabled: config.sandboxEnabled,
          sandboxNet: config.sandboxNet,
          sandboxReadOnly: config.sandboxReadOnly,
        ),
        projectToolScopePlugin(),
      ],
    ],
  );
  final resources = RuntimeResources();
  try {
    await runtime.activate();
    // The runtime owns its own scope resources; disposing it releases the
    // provider factory (and any plugin-owned cleanup) exactly once.
    resources.own(runtime.dispose);
    final ledger = runtime.scope.lookup(spendLedgerServiceKey)!;
    final providers = runtime.scope.lookup(providerFactoryServiceKey)!;
    // The auto-mode classifier: a dedicated cheap model when `[permissions]
    // model` is set, else the main model. Best-effort — an unbuildable ref
    // (unknown provider, missing key) leaves it null and auto mode degrades to
    // plain prompting.
    final classifierRef =
        config.permissionClassifierModel ??
        '${config.provider}/${config.model}';
    PermissionClassifier? classifier;
    try {
      classifier = PermissionClassifier(
        providers.build(
          classifierRef,
          apiKeyOverride: classifierRef.startsWith('${config.provider}/')
              ? config.apiKey
              : null,
          maxTokens: config.maxTokens,
          streamIdleTimeout: config.streamIdleTimeout,
          requestTimeout: config.requestTimeout,
        ),
      );
    } catch (_) {
      classifier = null;
    }
    if (classifier != null) resources.own(classifier.provider.close);
    // A nested same-project run borrows the live scope (including its write
    // lock). Independent compositions construct independent tool instances —
    // each runtime's plugins build their own scope under
    // [projectToolScopeServiceKey]; the lookup is non-null because the two
    // project plugins above activated, or `toolScope` was borrowed verbatim.
    final tools =
        toolScope ?? runtime.scope.lookup(projectToolScopeServiceKey)!;
    final pipeline = AgentPipeline(
      mainIdentity: defaultPipeline.mainIdentity,
      tools: tools,
      promptContext:
          promptContext ??
          PromptContext(
            projectRoot: root,
            loadProjectContext: loadProjectContext ?? true,
            projectEnvironmentSource: () => projectEnvironmentBlock(root),
            repoSummarySource: () => repoSummaryBlock(root),
          ),
    );
    // One runtime quota shared by this scheduler's delegated jobs.
    final quota = AgentQuota(
      maxDepth: config.maxSubAgentDepth,
      maxLive: config.maxSubAgentConcurrency,
    );
    final scheduler = createScheduler(
      config: config,
      registry: registry,
      providers: providers,
      pipeline: pipeline,
      pauseGate: pauseGate,
      quota: quota,
    );
    resources.own(scheduler.dispose);
    return ExecutionRuntime(
      config: config,
      environment: env,
      providers: providers,
      policy: policy,
      pipeline: pipeline,
      scheduler: scheduler,
      spendLedger: ledger,
      pauseGate: pauseGate,
      classifier: classifier,
      resources: resources,
      pluginScope: runtime.scope,
    );
  } catch (_) {
    try {
      await resources.dispose();
    } catch (_) {}
    rethrow;
  }
}
