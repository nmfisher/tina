import 'dart:io';
import 'package:tina_mcp/tina_mcp.dart';
import 'mcp_console_plugin.dart';
import 'package:tina_grok_guard/tina_grok_guard.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_activity_tui/tina_activity_tui.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_self_update/tina_self_update.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_shell/tina_shell.dart';
import 'package:tina_system_instruction/tina_system_instruction.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_goals/tina_goals.dart';
import 'package:tina_compaction/tina_compaction.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_subagents/tina_subagents.dart';
import 'package:tina_file_resources/tina_file_resources.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_step_limit/tina_step_limit.dart';

const _workingContext = PluginCapability<ContextPlugin>('tina/working-context');

/// Explicit dependencies available to factories in the application assembly.
final class TuiPluginContext {
  const TuiPluginContext({
    required this.workingDirectory,
    required this.terminal,
    required this.tools,
    required this.providerFactory,
    required this.model,
    required this.currentModel,
    required this.switchModel,
    required this.modelCatalog,
    this.openStore,
    this.version = '0.0.0',
    this.restart,
    this.providerPolicy,
    required this.configPath,
    this.limits = const RequestLimits(),
    this.settings,
    this.readLimits,
    this.contextLoaded,
  });
  final String workingDirectory;
  final String configPath;
  final String version;
  final void Function(String)? restart;
  final ProviderPolicyPlugin? providerPolicy;
  final RequestLimits limits;
  final ScopedSettings? settings;
  final RequestLimits Function()? readLimits;
  final bool Function()? contextLoaded;
  RequestLimits get currentLimits => readLimits?.call() ?? limits;
  final Terminal terminal;
  final ToolsPlugin tools;
  final ProviderFactory providerFactory;
  final String model;
  final String Function() currentModel;
  final void Function(String) switchModel;
  final ModelCatalog Function() modelCatalog;
  final SessionStoreOpener? openStore;
}

/// Required host plugins also carry metadata, without becoming optional features.
List<PluginDefinition<TuiPluginContext>> basePluginDefinitions() => [
      PluginDefinition(
          'tina/system-instruction', (_) => const SystemInstructionPlugin(),
          description:
              'Supplies the agent identity and base instructions for conversations.'),
      PluginDefinition('tina/providers', (c) => c.providerPolicy!,
          settings: providerLimitSettings,
          provides: [modelAccess],
          description:
              'Connects configured models and providers and enforces request and token limits.'),
      PluginDefinition.dependingOn<TuiPluginContext, ModePolicySource>(
          'tina/mode',
          settings: [classifierInstructionSetting],
          dependency: modePolicySource,
          create: (c, source) => ModeTuiPlugin(policy: source.modePolicy),
          live: true,
          description:
              'Adds /mode and Shift-Tab controls for the tools permission policy.'),
    ];

Map<String, String> pluginDescriptions(
        PluginRegistry<TuiPluginContext> registry) =>
    {
      for (final id in registry.ids) id: registry.definition(id).description,
      for (final definition in basePluginDefinitions())
        definition.id: definition.description,
    };

/// This catalog alone grants first-party names. Extension registration on
/// the returned registry rejects the reserved namespace.
PluginRegistry<TuiPluginContext> firstPartyPlugins() => PluginRegistry(
      requiredCapabilities: [modelAccess],
      definitions: [
        ...basePluginDefinitions(),
        PluginDefinition<TuiPluginContext>(
            'tina/shell',
            (c) => ShellPlugin(
                terminal: c.terminal, workingDirectory: c.workingDirectory),
            description:
                'Runs !command or /shell command with your shell permissions, without sending it to a model.',
            live: true),
        PluginDefinition<TuiPluginContext>(
            'tina/session-controls',
            (c) => SessionControlsPlugin(
                terminal: c.terminal,
                currentModel: c.currentModel,
                switchModel: c.switchModel,
                modelCatalog: c.modelCatalog),
            settings: [defaultModelSetting],
            description:
                'Switches the active conversation model and clears its context and display.',
            live: true),
        PluginDefinition<TuiPluginContext>(
            'tina/step-limit',
            (c) => StepLimitConsolePlugin(
                configPath: c.configPath, settings: c.settings),
            settings: [stepLimitSetting],
            description:
                'Optionally limits foreground model rounds per turn. Multiple tool calls in one response count as one round. Zero means unlimited.',
            live: true),
        grokGuardDefinition<TuiPluginContext>(),
        PluginDefinition.dependingOn<TuiPluginContext, ModePolicySource>(
            'tina/mcp',
            dependency: modePolicySource,
            create: (c, source) => McpConsolePlugin(
                store: McpConfigStore(c.configPath),
                workingDirectory: c.workingDirectory,
                terminal: c.terminal,
                approve: source.modePolicy.request),
            live: true,
            description:
                'Connects configured MCP servers, discovers their tools and resources, and routes calls through the current approval mode. Local server commands run with your account privileges.'),
        updateTuiDefinition<TuiPluginContext>(),
        PluginDefinition<TuiPluginContext>(
            'tina/status-strip-tui', (_) => StatusStripTuiPlugin(),
            description:
                'Arranges the status bar: how plugin lines and the mode label share the strip under width pressure.',
            live: true),
        updateDefinition<TuiPluginContext>(
            version: (c) => c.version,
            terminal: (c) => c.terminal,
            restart: (c) => c.restart),
        approvalsDefinition<TuiPluginContext>(),
        approvalTuiDefinition<TuiPluginContext>(),
        PluginDefinition<TuiPluginContext>(
            'tina/approvals-stream', (_) => StreamApprovalChannel(),
            provides: [approvalChannel],
            description:
                'Delivers approval requests through a stream for an external interaction channel.'),
        PluginDefinition.dependingOn2<TuiPluginContext, ApprovalRequester,
                ModelAccess>('tina/tools',
            settings: [readOnlyDirectoriesSetting, writeDirectoriesSetting],
            first: approvalRequester,
            second: modelAccess,
            provides: [toolProvider, modePolicySource],
            create: (c, approvals, models) {
          c.tools.modePolicy
            ..approvals = approvals
            ..terminal = c.terminal
            ..classifier = PermissionClassifier(
                () => models.mainProvider(c.currentModel()),
                readInstruction: () =>
                    c.settings?.read(classifierInstructionSetting).value ?? '');
          return c.tools;
        },
            description:
                'Provides sandboxed file, search and shell tools with permission policy and approval routing.'),
        PluginDefinition.dependingOn<TuiPluginContext, ModelAccess>(
            'tina/classification',
            dependency: modelAccess,
            create: (c, models) => ClassificationConsolePlugin.configured(
                terminal: c.terminal,
                configPath: c.configPath,
                createProvider: () => models.mainProvider(c.currentModel())),
            description:
                'Classifies user input and Git operations, learns reusable categories from Other using the active model, and counts selections. Displays results without changing how the agent responds.',
            live: true),
        PluginDefinition<TuiPluginContext>(
            'tina/panels-tui', (c) => PanelsTuiPlugin(terminal: c.terminal),
            description:
                'Opens multiple conversations in terminal panels and lets you switch between them.',
            live: false),
        PluginDefinition<TuiPluginContext>(
            'tina/chat-tui',
            (c) => ChatTuiPlugin(
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
                    : () => c.providerPolicy!.sessionEstimatedTokens),
            settings: [themeSetting, terminalAlertsSetting],
            description:
                'Displays conversation history, model responses, tool calls, timestamps and token spend.',
            live: true),
        PluginDefinition<TuiPluginContext>(
            'tina/activity-tui',
            (c) =>
                ActivityTuiPlugin(terminal: c.terminal, printTranscript: false),
            description:
                'Shows tool progress, results, file diffs and subagent activity in the activity browser.',
            live: true),
        PluginDefinition<TuiPluginContext>(
            'tina/persistence',
            (c) => PersistencePlugin(
                openStore: c.openStore!, settings: c.settings),
            description:
                'Saves conversation history in SQLite so sessions can be listed and resumed.',
            live: false),
        PluginDefinition.dependingOn<TuiPluginContext, ApprovalRequester>(
            'tina/plans',
            dependency: approvalRequester,
            create: (c, approvals) => PlansConsolePlugin(
                  terminal: c.terminal,
                  // Plan consent is always human, never a tool-safety judgment.
                  approver: (request, reason) async {
                    final decision = await approvals.request(
                      operation: 'approve plan',
                      target: request.path,
                      reason: reason,
                      kind: ApprovalKind.confirmation,
                    );
                    return decision == ApprovalDecision.allow
                        ? Approval.yes
                        : Approval.no;
                  },
                ),
            description:
                'Lets the agent maintain a task plan and track progress through its steps.',
            live: true),
        PluginDefinition<TuiPluginContext>(
            'tina/goals', (c) => GoalsPlugin(terminal: c.terminal),
            description:
                'Tracks an active goal and its progress across turns, with optional token budgets.',
            live: true),
        PluginDefinition<TuiPluginContext>(
            'tina/auto-compact',
            (c) => CompactionPlugin(
                terminal: c.terminal,
                canCompact: () => !(c.contextLoaded?.call() ?? false)),
            description:
                'Summarizes older conversation history when context grows large to make room for more work.',
            live: true),
        PluginDefinition.dependingOn<TuiPluginContext, ToolSessionSource>(
            'tina/context',
            dependency: toolProvider,
            provides: [_workingContext],
            create: (c, _) => ContextPlugin.sessionMirror(
                onMirrorReady: (file) => c.tools.sandbox.grants
                    .rememberExact(file.resolveSymbolicLinksSync())),
            description:
                'Experimental: lets the agent edit its working conversation through a temporary file. Preserves the original log and pauses automatic and manual compaction while loaded. Changes require restart.',
            live: false),
        PluginDefinition.dependingOn<TuiPluginContext, ContextPlugin>(
            'tina/context-tui',
            dependency: _workingContext,
            create: (c, context) =>
                ContextTuiPlugin(context: context, terminal: c.terminal),
            description:
                'Adds /context to inspect accepted working messages, estimated tokens, pending file edits and the latest accepted changes. Requires tina/context.',
            live: true),
        PluginDefinition.dependingOn2<TuiPluginContext, ToolSessionSource,
                ModelAccess>('tina/subagents',
            first: toolProvider,
            second: modelAccess,
            settings: subagentSettings,
            create: (c, parentTools, models) => SubagentsPlugin(
                  config: SubagentsConfig(
                      maxDepth: c.limits.childDepth,
                      maxConcurrency: c.limits.childConcurrency,
                      tokenBudget: 0),
                  configFor: () => SubagentsConfig(
                      maxDepth: c.currentLimits.childDepth,
                      maxConcurrency: c.currentLimits.childConcurrency,
                      tokenBudget: 0),
                  sessionFactory: standardChildFactory(
                    parentTools: parentTools,
                    providerFactory: models.childProvider,
                    model: c.model,
                    currentModel: c.currentModel,
                    childPlugins: () => [
                      const SystemInstructionPlugin(),
                      if (c.openStore != null)
                        PersistencePlugin(openStore: c.openStore!),
                    ],
                  ),
                ),
            description:
                'Lets the agent delegate work to child sessions with bounded depth and concurrency.',
            live: false),
        PluginDefinition<TuiPluginContext>(
            'tina/file-resources',
            (c) => FileResourcesPlugin(
                  config: FileResourcesConfig(
                    directory:
                        Directory('${c.workingDirectory}/.tina/skills').path,
                    heading: '## Skills',
                  ),
                ),
            description:
                'Reads skill folders from the workspace and makes their instructions available to the agent.',
            live: true),
      ],
    );
