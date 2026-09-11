import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/environment/environment_prompt.dart';
import 'package:tina_app/src/platform/environment.dart';
import 'package:tina_app/src/composition/agent_composition.dart';
import 'package:tina_app/src/composition/execution_profile.dart';
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
///
/// [driverFactory] / [persistence] mount the composition-level P5/P6
/// replacement seams on the built scheduler (see [AppComposition.driverFactory]
/// / [AppComposition.persistence]); null (the default) keeps the built-in
/// behavior.
///
/// [executionPlugins] overrides the default execution plugin profile
/// ([defaultExecutionPlugins]) wholesale. Null (the default) builds the
/// default profile; a borrowed [toolScope] mounts only the profile's
/// conversation-owned plugins. An override is validated by the runtime BEFORE
/// any factory runs, so a bad profile fails before any provider, ledger, or
/// scheduler exists.
Future<ExecutionRuntime> buildExecutionRuntime({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  Environment? environment,
  String? projectRoot,
  ProjectToolScope? toolScope,
  PromptContext? promptContext,
  bool? loadProjectContext,
  AgentDriverFactory? driverFactory,
  SubAgentPersistenceFactory? persistence,
  List<PluginDescriptor>? executionPlugins,
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
  // The plugin profile: the default five-plugin list by default, or the
  // caller's override. See [defaultExecutionPlugins] for the ordering story:
  // the ledger is created BEFORE anything can build a provider, the
  // decorators stage mounts before the factory (order-only edge), and the
  // third stage owns the project itself — capabilities, then the tool scope
  // assembled from them. When BORROWING a live same-project scope the profile
  // (default or override) is trimmed to the conversation-owned plugins — the
  // borrowed scope's capabilities stay exactly the ones its owner built.
  final profile = executionPlugins ??
      defaultExecutionPlugins(
        config: config,
        registry: registry,
        pauseGate: pauseGate,
        providerDecorators: const [],
        projectRoot: root,
        environment: env,
        sandboxEnabled: config.sandboxEnabled,
        sandboxNet: config.sandboxNet,
        sandboxReadOnly: config.sandboxReadOnly,
      );
  final runtime = PluginRuntime(
    name: 'execution',
    plugins:
        toolScope == null ? profile : borrowedScopePlugins(profile),
  );
  final resources = RuntimeResources();
  try {
    await runtime.activate();
    // The runtime owns its own scope resources; disposing it releases the
    // provider factory (and any plugin-owned cleanup) exactly once.
    resources.own(runtime.dispose);
    final ledger = runtime.scope.lookup(spendLedgerServiceKey)!;
    final providers = runtime.scope.lookup(providerFactoryServiceKey)!;
    // A nested same-project run borrows the live scope (including its write
    // lock). Independent compositions construct independent tool instances —
    // each runtime's plugins build their own scope under
    // [projectToolScopeServiceKey]; the lookup is non-null because the two
    // project plugins above activated, or `toolScope` was borrowed verbatim.
    // A profile that omits the tool-scope plugin surfaces HERE, before any
    // provider is built, as a composition error.
    final tools =
        toolScope ?? runtime.scope.lookup(projectToolScopeServiceKey);
    if (tools == null) {
      throw PluginCompositionError(
        'the execution profile provides no project tool scope',
        pluginId: 'tina.engine.project-tool-scope',
      );
    }
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
    // Resolve the SELECTED driver factory from the active scope (fix: the
    // scheduler's driverFactory param and a mounted driverPlugin were two
    // disconnected seams). Explicit param wins (a caller-level override);
    // otherwise the scope's mounted factory; otherwise null — the default
    // factory behavior. Missing service keys produce actionable composition
    // errors, never a null assertion after activation.
    final scopeDriverFactory =
        runtime.scope.lookup(agentDriverFactoryServiceKey);
    final resolvedDriverFactory = driverFactory ?? scopeDriverFactory;
    final scheduler = createScheduler(
      config: config,
      registry: registry,
      providers: providers,
      pipeline: pipeline,
      pauseGate: pauseGate,
      quota: quota,
      driverFactory: resolvedDriverFactory,
      persistence: persistence,
      // Scope-resolved plugin contributions, in registration order, wired to
      // their actual consumers (guards/hooks/observers ride the scheduler;
      // prompt contributors resolve in buildAgent through the scope).
      guards: toolGuardsFromScope(runtime.scope),
      executionHooks: toolExecutionHooksFromScope(runtime.scope),
      resultHooks: toolResultHooksFromScope(runtime.scope),
      observers: toolObserversFromScope(runtime.scope),
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
