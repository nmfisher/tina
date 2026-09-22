import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/composition/runtime_plugins.dart';
import 'live_quotas.dart';
import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/platform/environment.dart';

/// Plugin ids of the PROJECT-OWNED stages of the default profile: the
/// capabilities stage and the tool scope assembled from it. A runtime that
/// BORROWS a live same-project tool scope never mounts these — the borrowed
/// scope's capabilities stay exactly the ones its owner built. Everything
/// else mounts: the conversation-owned prefix (ledger, decorator stage,
/// provider factory) AND any conversation extension the profile carries
/// (a [driverPlugin], a custom conversation plugin). Selecting by what is
/// project-owned — not by an allowlist of known ids — is the point: an
/// allowlist silently dropped every extension it did not know, so a
/// borrowed runtime lost its driver factory.
const List<String> _workspaceOwnedPluginIds = [
  'tina.engine.workspace-capabilities',
  'tina.engine.workspace-tool-scope',
];

/// The default execution plugin profile — the exact plugin list
/// [buildExecutionRuntime] mounts, in the same declared order:
///
/// 1. `tina.engine.skills` — the scoped, lazy skill registry.
///    `tina.engine.agents-instructions` — request-time project instructions.
/// 2. `tina.app.spend-ledger` — the conversation-wide [SpendLedger]. The
///    ledger is created BEFORE anything can build a provider, so the runtime
///    factory meters every provider built from here on — the startup provider
///    (AppComposition.buildStartupProvider), per-conversation providers, and
///    every sub-agent. (An injected test provider bypasses the factory and so
///    isn't metered, which is fine for fakes.) The ordering is guaranteed by
///    declaration order and by the factory plugin's explicit `requires` edge.
/// 3. `tina.app.live-quotas` — shared cap sources for existing and future
///    agents; changing caps preserves their independently accumulated spend.
/// 4. `tina.app.provider-decorators` — decorator contributions mount BEFORE
///    the factory: the factory plugin requires the ProviderDecoratorStage
///    marker (an order-only edge), so every registered decorator contribution
///    exists before the factory builds its policy stack. Empty by default —
///    the factory then wraps metering only, exactly the pre-plugin behavior.
/// 5. `tina.app.provider-factory` — the conversation-owned
///    [LlmProviderFactory], with `orderOnDecoratorStage: true`.
/// 6. `tina.engine.workspace-capabilities` and 7.
///    `tina.engine.workspace-tool-scope` — the stage that owns the project:
///    capabilities, then the tool scope assembled from them (the scope plugin
///    `requires` the capabilities key, which fixes the order).
///
/// The profile is safe to activate in a bare runtime: every dependency is
/// satisfied inside the list itself (the ledger and decorator-stage keys by
/// the plugins above the factory, the capabilities key by the capabilities
/// plugin), so no parent-scope services are required.
///
/// [pauseGate] defaults to a fresh [PauseGate]; pass the runtime's gate so
/// metering pauses on the same switch. The sandbox flags come from the
/// caller — [buildExecutionRuntime] passes the config's values.
List<PluginDescriptor> defaultExecutionPlugins({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  PauseGate? pauseGate,
  required List<ProviderDecorator> providerDecorators,
  required String workspaceRoot,
  required Environment environment,
  required bool sandboxEnabled,
  required bool sandboxNet,
  required bool sandboxReadOnly,

  /// Who disabled the sandbox, when [sandboxEnabled] is false — forwarded to
  /// [WorkspaceCapabilities] for the one-time startup log. Null when enabled.
  String? sandboxOffReason,
}) {
  final gate = pauseGate ?? PauseGate();
  return [
    skillsPlugin(),
    agentsInstructionsPlugin(),
    spendLedgerPlugin(config),
    liveQuotasPlugin(config),
    providerDecoratorsPlugin(providerDecorators),
    providerFactoryPlugin(config, registry, gate, orderOnDecoratorStage: true),
    workspaceCapabilitiesPlugin(
      workspaceRoot: workspaceRoot,
      env: environment.env,
      sandboxEnabled: sandboxEnabled,
      sandboxNet: sandboxNet,
      sandboxReadOnly: sandboxReadOnly,
      sandboxOffReason: sandboxOffReason,
    ),
    workspaceToolScopePlugin(),
  ];
}

/// The plugins of [plugins] a borrowing runtime mounts: everything EXCEPT the
/// project-owned stages ([_workspaceOwnedPluginIds]) — the conversation-owned
/// prefix rides along in the list's own order, and so does any conversation
/// extension (a driver factory plugin, a custom conversation plugin). The
/// borrowed scope keeps the capabilities its owner built; the borrowing
/// conversation keeps its own extensions.
List<PluginDescriptor> borrowedScopePlugins(List<PluginDescriptor> plugins) => [
  for (final plugin in plugins)
    if (!_workspaceOwnedPluginIds.contains(plugin.id)) plugin,
];
