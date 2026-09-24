import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/platform/environment.dart';
import 'package:tina_app/src/composition/agent_composition.dart';
import 'package:tina_app/src/composition/execution_profile.dart';
import 'package:tina_app/src/composition/runtime_resources.dart';

import 'package:tina_app/src/execution/workspace_execution.dart';
import '../execution/interrupts.dart';
import 'package:tina_app/src/execution/input_routes.dart';

class ExecutionRuntime implements WorkspaceExecution {
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

  /// Drafts general-but-safe allow patterns for the approval modal's `[r]`
  /// rewrite choice; null when no classifier provider could be built.
  final RegexSuggester? regexSuggester;
  final RuntimeResources resources;

  /// The runtime's own plugin scope (ledger, provider factory, and — when the
  /// runtime owns the project — the built capabilities and tool scope).
  final PluginScope pluginScope;
  late final InputRoutes inputRoutes = InputRoutes(pluginScope);
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
    required this.regexSuggester,
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
/// [plugins] appends extensions to that profile, without replacing built-ins.
Future<ExecutionRuntime> buildExecutionRuntime({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  Environment? environment,
  String? workspaceRoot,
  WorkspaceToolScope? toolScope,
  PromptContext? promptContext,
  bool? loadWorkspaceContext,
  AgentDriverFactory? driverFactory,
  SubAgentPersistenceFactory? persistence,

  /// The conversation-wide pause gate; a fresh gate when null (the
  /// pre-existing behavior). [buildAppComposition] forwards the launcher's
  /// gate so composition plugins (PT0 explore_project) share it — metering
  /// and pause must observe one switch, not one per surface.
  PauseGate? pauseGate,
  List<PluginDescriptor>? executionPlugins,
  List<PluginDescriptor> plugins = const [],
}) async {
  final env = environment ?? const PlatformEnvironment();
  final root = p.normalize(
    p.absolute(
      workspaceRoot ??
          toolScope?.workspaceRoot ??
          promptContext?.workspaceRoot ??
          Directory.current.path,
    ),
  );
  if (toolScope != null && toolScope.workspaceRoot != root) {
    throw ArgumentError('toolScope must belong to the requested workspaceRoot');
  }
  if (promptContext != null &&
      (promptContext.workspaceRoot != root ||
          (loadWorkspaceContext != null &&
              loadWorkspaceContext != promptContext.loadWorkspaceContext))) {
    throw ArgumentError(
      'promptContext must match the requested project and trust',
    );
  }
  final gate = pauseGate ?? PauseGate();
  final policy = config.buildPolicy();
  // The plugin profile: the default five-plugin list by default, or the
  // caller's override. See [defaultExecutionPlugins] for the ordering story:
  // the ledger is created BEFORE anything can build a provider, the
  // decorators stage mounts before the factory (order-only edge), and the
  // third stage owns the project itself — capabilities, then the tool scope
  // assembled from them. When BORROWING a live same-project scope the profile
  // (default or override) is trimmed to the conversation-owned plugins — the
  // borrowed scope's capabilities stay exactly the ones its owner built.
  final baseProfile =
      executionPlugins ??
      defaultExecutionPlugins(
        config: config,
        registry: registry,
        pauseGate: gate,
        providerDecorators: const [],
        workspaceRoot: root,
        environment: env,
        sandboxEnabled: config.sandboxEnabled,
        sandboxNet: config.sandboxNet,
        sandboxReadOnly: config.sandboxReadOnly,
        sandboxOffReason: config.sandboxOffReason,
      );
  final profile = [
    invocationPlugin(),
    interruptionPlugin(),
    ...baseProfile,
    ...plugins,
  ];
  final mounted = toolScope == null ? profile : borrowedScopePlugins(profile);
  // Fix (P2): required application services are validated BEFORE activation —
  // the mounted profile must DECLARE the ledger and the provider factory, so
  // an incomplete profile fails here as a composition error before ANY
  // factory runs. (Previously the factory for the ledger/provider ran, and
  // only the later null assertion on the lookup crashed — with provider
  // construction side effects already behind it.)
  final requiredServices = <(ServiceKey, String)>[
    (spendLedgerServiceKey, 'tina.app.spend-ledger'),
    (providerFactoryServiceKey, 'tina.app.provider-factory'),
  ];
  for (final (key, pluginId) in requiredServices) {
    final declared = mounted.any(
      (plugin) => plugin.provides.any((k) => k == key),
    );
    if (!declared) {
      throw PluginCompositionError(
        'the execution profile provides no $key '
        '(required application service missing before activation)',
        pluginId: pluginId,
      );
    }
  }
  // Fix: the required TOOL scope is validated BEFORE activation too — a
  // profile that mounts no tool-scope stage (and borrows no scope) fails
  // here, before any factory runs and before anything is acquired.
  // (Previously this was only checked after activation: the ledger and the
  // provider factory had already activated and acquired their resources when
  // the composition threw, and nothing disposed what was acquired.)
  if (toolScope == null &&
      !mounted.any(
        (plugin) => plugin.provides.any((k) => k == workspaceToolScopeServiceKey),
      )) {
    throw PluginCompositionError(
      'the execution profile provides no project tool scope '
      '(required tool-scope stage missing before activation)',
      pluginId: 'tina.engine.workspace-tool-scope',
    );
  }
  // A borrowed tool scope stays with its owner: expose it to this runtime's
  // plugins through a BORROWED parent scope. A parent binding resolves for
  // pre-activation validation and for every plugin factory's require(), yet
  // teardown never touches parent-owned bindings or resources — disposing
  // this runtime releases only its own root scope, so the lender's resources
  // are released exactly once, by the lender. Without it, an extension that
  // requires workspaceToolScopeServiceKey fails dependency validation even
  // though composition handed it the scope.
  final runtime = PluginRuntime(
    name: 'execution',
    plugins: mounted,
    parent: toolScope == null
        ? null
        : (PluginScope('borrowed-workspace-tools')
            ..provide(workspaceToolScopeServiceKey, toolScope)),
  );
  final resources = RuntimeResources();
  // Fix: cleanup ownership is established BEFORE activation — the runtime's
  // teardown is owned from the moment `resources` exists, so any resource
  // acquired during activation is released even when a later composition
  // step throws. (Previously this ran only after activation: a failure in
  // between left activation's resources with no owner and leaked them.)
  resources.own(runtime.dispose);
  try {
    await runtime.activate();
    // Post-activation re-check (defense in depth): a plugin that declared a
    // key but failed to bind it still surfaces as a composition error, not a
    // null assertion further down.
    void requireService(ServiceKey key, String pluginId) {
      if (!runtime.scope.isAdmitting || runtime.scope.lookup(key) == null) {
        throw PluginCompositionError(
          'the execution profile provides no $key '
          '(required application service missing after activation)',
          pluginId: pluginId,
        );
      }
    }

    requireService(spendLedgerServiceKey, 'tina.app.spend-ledger');
    requireService(providerFactoryServiceKey, 'tina.app.provider-factory');
    // A nested same-project run borrows the live scope (including its write
    // lock). Independent compositions construct independent tool instances —
    // each runtime's plugins build their own scope under
    // [workspaceToolScopeServiceKey]; the lookup is non-null because the two
    // project plugins above activated, or `toolScope` was borrowed verbatim.
    // Post-activation re-check (defense in depth): a profile that omitted
    // the tool-scope stage fails before activation now, but a plugin that
    // DECLARED workspaceToolScopeServiceKey without binding it still surfaces
    // here as a composition error.
    final tools = toolScope ?? runtime.scope.lookup(workspaceToolScopeServiceKey);
    if (tools == null) {
      throw PluginCompositionError(
        'the execution profile provides no project tool scope',
        pluginId: 'tina.engine.workspace-tool-scope',
      );
    }
    // The runtime owns its own scope resources; its teardown is already
    // owned by `resources` (armed before activation), so the single dispose
    // below releases the provider factory (and any plugin-owned cleanup)
    // exactly once.
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
    // The `[r] rewrite-to-regex` suggester shares the classifier's provider —
    // one more judgment over the same cheap transport (already owned above).
    // Null (unbuildable provider) degrades the rewrite choice to the literal
    // escaped target.
    final regexSuggester = classifier == null
        ? null
        : RegexSuggester(classifier.provider);
    // A nested same-project run borrows the live scope (including its write
    // lock). Independent compositions construct independent tool instances —
    // each runtime's plugins build their own scope under
    // [workspaceToolScopeServiceKey]; the lookup is non-null because the two
    // project plugins above activated, or `toolScope` was borrowed verbatim.
    final pipeline = AgentPipeline(
      mainIdentity: defaultPipeline.mainIdentity,
      tools: tools,
      promptContext:
          promptContext ??
          PromptContext(
            workspaceRoot: root,
            loadWorkspaceContext: loadWorkspaceContext ?? true,
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
    final scopeDriverFactory = runtime.scope.lookup(
      agentDriverFactoryServiceKey,
    );
    final resolvedDriverFactory = driverFactory ?? scopeDriverFactory;
    final scheduler = createScheduler(
      config: config,
      registry: registry,
      providers: providers,
      pipeline: pipeline,
      pauseGate: gate,
      quota: quota,
      driverFactory: resolvedDriverFactory,
      persistence: persistence,
      // Scope-resolved plugin contributions, in registration order, wired to
      // their actual consumers (guards/hooks/observers ride every delegated
      // driver build; the scope carries prompt sections into delegated
      // identity resolution). Also the main-agent prompt source: buildAgent
      // resolves through the same scope.
      guards: toolGuardsFromScope(runtime.scope),
      executionHooks: toolExecutionHooksFromScope(runtime.scope),
      toolChecks: toolChecksFromScope(runtime.scope),
      resultHooks: toolResultHooksFromScope(runtime.scope),
      observers: toolObserversFromScope(runtime.scope),
      scope: runtime.scope,
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
      pauseGate: gate,
      classifier: classifier,
      regexSuggester: regexSuggester,
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
