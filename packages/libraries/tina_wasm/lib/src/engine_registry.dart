/// The wasm engine's plugin registry: the portable subset of the
/// first-party set, registered exactly as the native catalog registers
/// its members — the same plugin classes (system instructions, provider
/// policy, mode controls, approvals channel, session controls), with
/// `tina/tools` provided by the portable file-tools plugin.
library;

import 'package:tina_approvals/tina_approvals.dart' as tina_approvals;
import 'package:tina_chat/tina_chat.dart'
    show ChatPlugin, terminalAlertsSetting;
import 'package:tina_host/tina_host.dart' hide PluginManager;
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_session_controls/tina_session_controls.dart';
import 'package:tina_system_instruction/tina_system_instruction.dart';

import 'package:tina/src/session_context.dart';

import 'portable_tools_plugin.dart';
import 'plugin_admin.dart';
import 'plugin_manager.dart';
import 'remote_prompt_plugin.dart';
import 'wasm_persistence_plugin.dart';
import 'wasi_session_store.dart';

/// `tina/mode-policy`, as the native catalog's tools plugin provides it.
const modePolicySource = PluginCapability<ModePolicySource>('tina/mode-policy');

/// The model access the host requires a provider plugin to supply.
const modelAccess = PluginCapability<ModelAccess>('tina/model-access');

/// `tina/tools`, provided by the portable plugin.
const toolProvider = PluginCapability<ModePolicySource>('tina/tools');

// The delivery-channel capability, exactly as the native catalog sees it.
const approvalChannel = tina_approvals.approvalChannel;

// The approval requester the tools plugin routes asks through.
const approvalRequester = tina_approvals.approvalRequester;

/// The wasm registry: every first-party plugin whose dependency tree
/// compiles without `dart:io`/`dart:ffi`, driven by the same definitions
/// the native catalog uses. [persistenceStore], when the composition
/// root loaded one, registers `tina/persistence` over the WASI store —
/// the config's enabled list still decides whether a session uses it,
/// and [onPersistence] receives the created plugin (the root flushes it
/// at shutdown).
PluginRegistry<SessionPluginContext> wasmEngineRegistry({
  WasiSessionStore? persistenceStore,
  void Function(WasmPersistencePlugin plugin)? onPersistence,
  bool includeRemotePromptPlugin = false,
  required PromptPluginHostBridge remotePromptHost,
}) {
  // One lease book shared by the prompt adapter and the /plugins command:
  // the manager is the single writer, the adapter derives its lease from
  // it, so a reload from the command is adopted by the next prompt.
  final promptManager =
      includeRemotePromptPlugin ? PluginManager(bridge: remotePromptHost) : null;
  return PluginRegistry<SessionPluginContext>(
  requiredCapabilities: [modelAccess],
  definitions: [
    if (persistenceStore != null)
      PluginDefinition<SessionPluginContext>(
        'tina/persistence',
        (c) {
          final plugin = WasmPersistencePlugin(
            store: persistenceStore,
            settings: c.settings,
          );
          onPersistence?.call(plugin);
          return plugin;
        },
        live: false,
        description:
            'Saves conversations in the preopened store, resumes sessions.',
      ),
    PluginDefinition<SessionPluginContext>(
      'tina/system-instruction',
      (_) => const SystemInstructionPlugin(),
      description: 'Supplies the agent identity and base instructions for conversations.',
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/providers',
      (c) => c.providerPolicy!,
      provides: [modelAccess],
      description: 'Connects configured models and providers and enforces request and token limits.',
    ),
    PluginDefinition.dependingOn<SessionPluginContext, ModePolicySource>(
      'tina/mode',
      dependency: modePolicySource,
      create: (c, source) => ModeControlsPlugin(source.modePolicy),
      live: true,
      description: 'Adds mode controls for the tools permission policy.',
    ),
    PluginDefinition.dependingOn<
      SessionPluginContext,
      tina_approvals.ApprovalRequester
    >(
      'tina/tools',
      dependency: approvalRequester,
      create: (c, approvals) {
        final plugin = c.tools as PortableToolsPlugin;
        plugin.attachApprovals(approvals);
        return plugin;
      },
      provides: [toolProvider, modePolicySource],
      description: 'File tools (read, write, edit) over the preopened workspace with permission policy.',
    ),
    tina_approvals.approvalsDefinition<SessionPluginContext>(),
    PluginDefinition<SessionPluginContext>(
      'tina/approvals-stream',
      (_) => tina_approvals.StreamApprovalChannel(),
      provides: [approvalChannel],
      description: 'Delivers approval requests to the attached client over the pipes protocol.',
    ),
    PluginDefinition<SessionPluginContext>(
      'tina/session-controls',
      (c) => SessionControlsPlugin(
        terminal: c.terminal,
        modelCatalog: c.modelCatalog,
        currentModel: c.currentModel,
        switchModel: c.switchModel,
      ),
      description: 'Conversation controls (model, reasoning, stop).',
    ),
    // The live chat projection: token streaming reaches the attached front
    // end as `tina/chat-tui` feature previews in snapshot events. The same
    // definition the native catalog serves (snapshot_catalog maps it).
    PluginDefinition<SessionPluginContext>(
      'tina/chat-tui',
      (c) => ChatPlugin(
        model: c.model,
        tokenCap: c.limits.sessionTokens,
        currentTokenCap: () => c.currentLimits.sessionTokens,
        showSessionId: c.openStore != null,
        terminalAlertsEnabled: () =>
            c.settings?.read(terminalAlertsSetting).value ?? true,
        sessionTokens: c.providerPolicy == null
            ? null
            : () => c.providerPolicy!.sessionTokens,
        sessionEstimatedTokens: c.providerPolicy == null
            ? null
            : () => c.providerPolicy!.sessionEstimatedTokens,
      ),
      description:
          'Projects the live conversation preview (streaming tokens, model, '
          'token spend) to the attached front end.',
      live: true,
    ),
    if (includeRemotePromptPlugin) ...[
      PluginDefinition<SessionPluginContext>(
        RemotePromptPlugin.pluginId,
        (_) => RemotePromptPlugin(remotePromptHost, manager: promptManager),
        live: true,
        description: 'Adds one host-mediated prompt section per turn.',
      ),
      PluginDefinition<SessionPluginContext>(
        WasmPluginAdminPlugin.pluginId,
        (c) => WasmPluginAdminPlugin(
          manager: promptManager!,
          terminal: c.terminal,
        ),
        description: 'Wasm plugin status and reload (/plugins).',
      ),
    ],
  ],
);
}
