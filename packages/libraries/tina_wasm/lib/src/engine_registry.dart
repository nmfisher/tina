/// The wasm engine's plugin registry: the portable subset of the
/// first-party set, registered exactly as the native catalog registers
/// its members — the same plugin classes (system instructions, provider
/// policy, mode controls, approvals channel, session controls), with
/// `tina/tools` provided by the portable file-tools plugin.
library;

import 'package:classification/permissions.dart' show PermissionClassifier;
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_session_controls/tina_session_controls.dart';
import 'package:tina_system_instruction/tina_system_instruction.dart';

import 'package:tina/src/session_context.dart';

/// `tina/mode-policy`, as the native catalog's tools plugin provides it.
const modePolicySource = PluginCapability<ModePolicySource>('tina/mode-policy');

/// The model access the host requires a provider plugin to supply.
const modelAccess = PluginCapability<ModelAccess>('tina/model-access');

/// `tina/tools`, provided by the portable plugin.
const toolProvider = PluginCapability<ModePolicySource>('tina/tools');

/// The tools channel the headless assembly selects.
const approvalChannel = PluginCapability<ApprovalChannel>('tina/approvals-stream');

/// Builds the wasm registry: every first-party plugin whose dependency
/// tree compiles without `dart:io`/`dart:ffi`, driven by the same
/// definitions the native catalog uses.
PluginRegistry<SessionPluginContext> wasmEngineRegistry() =>
    PluginRegistry<SessionPluginContext>(
      requiredCapabilities: [modelAccess],
      definitions: [
        PluginDefinition<SessionPluginContext>(
          'tina/system-instruction',
          (_) => const SystemInstructionPlugin(),
          description:
              'Supplies the agent identity and base instructions for conversations.',
        ),
        PluginDefinition<SessionPluginContext>(
          'tina/providers',
          (c) => c.providerPolicy!,
          provides: [modelAccess],
          description:
              'Connects configured models and providers and enforces request and token limits.',
        ),
        PluginDefinition.dependingOn<SessionPluginContext, ModePolicySource>(
          'tina/mode',
          dependency: modePolicySource,
          create: (c, source) => ModeControlsPlugin(source.modePolicy),
          live: true,
          description:
              'Adds mode controls for the tools permission policy.',
        ),
        PluginDefinition<SessionPluginContext>(
          'tina/tools',
          (c) => c.tools as AgentPlugin,
          provides: [toolProvider, modePolicySource],
          description:
              'File tools (read, write, edit) over the preopened workspace with permission policy.',
        ),
        PluginDefinition<SessionPluginContext>(
          'tina/approvals-stream',
          (_) => StreamApprovalChannel(),
          provides: [approvalChannel],
          description:
              'Delivers approval requests to the attached client over the pipes protocol.',
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
      ],
    );
