import 'dart:io';
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
import 'package:tina_system_instruction/tina_system_instruction.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_goals/tina_goals.dart';
import 'package:tina_compaction/tina_compaction.dart';
import 'package:tina_subagents/tina_subagents.dart';
import 'package:tina_file_resources/tina_file_resources.dart';

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
    this.models = const [],
    this.providerNames = const {},
    this.modelNames = const {},
    this.openStore,
    this.version = '0.0.0',
    this.providerPolicy,
    required this.configPath,
    this.limits = const RequestLimits(),
  });
  final String workingDirectory;
  final String configPath;
  final String version;
  final ProviderPolicyPlugin? providerPolicy;
  final RequestLimits limits;
  final Terminal terminal;
  final ToolsPlugin tools;
  final ProviderFactory providerFactory;
  final String model;
  final String Function() currentModel;
  final void Function(String) switchModel;
  final List<String> models;
  final Map<String, String> providerNames;
  final Map<String, String> modelNames;
  final SessionStoreOpener? openStore;
}

/// Required host plugins also carry metadata, without becoming optional features.
List<PluginDefinition<TuiPluginContext>> basePluginDefinitions() => [
      PluginDefinition(
          'tina/system-instruction', (_) => const SystemInstructionPlugin(),
          description:
              'Supplies the agent identity and base instructions for conversations.'),
      PluginDefinition('tina/providers', (c) => c.providerPolicy!,
          provides: [modelAccess],
          description:
              'Connects configured models and providers and enforces request and token limits.'),
      PluginDefinition.dependingOn<TuiPluginContext, ModePolicySource>(
          'tina/mode',
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
            'tina/session-controls',
            (c) => SessionControlsPlugin(
                terminal: c.terminal,
                currentModel: c.currentModel,
                switchModel: c.switchModel,
                models: c.models,
                providerNames: c.providerNames,
                modelNames: c.modelNames),
            description:
                'Switches the active conversation model and clears its context and display.',
            live: true),
        PluginDefinition<TuiPluginContext>('tina/step-limit',
            (c) => StepLimitConsolePlugin(configPath: c.configPath),
            description:
                'Optionally limits foreground model rounds per turn. Multiple tool calls in one response count as one round. Zero means unlimited; the numeric setting is global.',
            live: true),
        grokGuardDefinition<TuiPluginContext>(),
        updateTuiDefinition<TuiPluginContext>(),
        updateDefinition<TuiPluginContext>(
            version: (c) => c.version, terminal: (c) => c.terminal),
        approvalsDefinition<TuiPluginContext>(),
        approvalTuiDefinition<TuiPluginContext>(),
        PluginDefinition<TuiPluginContext>(
            'tina/approvals-stream', (_) => StreamApprovalChannel(),
            provides: [approvalChannel],
            description:
                'Delivers approval requests through a stream for an external interaction channel.'),
        PluginDefinition.dependingOn2<TuiPluginContext, ApprovalRequester,
                ModelAccess>('tina/tools',
            first: approvalRequester,
            second: modelAccess,
            provides: [toolProvider, modePolicySource],
            create: (c, approvals, models) {
          c.tools.modePolicy
            ..approvals = approvals
            ..terminal = c.terminal
            ..classifier =
                PermissionClassifier(() => models.mainProvider(c.model));
          return c.tools;
        },
            description:
                'Provides sandboxed file, search and shell tools with permission policy and approval routing.'),
        PluginDefinition<TuiPluginContext>(
            'tina/classification',
            (c) => ClassificationConsolePlugin.configured(
                terminal: c.terminal, configPath: c.configPath),
            description:
                'Identifies project questions, instructions and Git operations. Displays results without changing how the agent responds.',
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
                showSessionId: c.openStore != null,
                sessionTokens: c.providerPolicy == null
                    ? null
                    : () => c.providerPolicy!.sessionTokens,
                sessionEstimatedTokens: c.providerPolicy == null
                    ? null
                    : () => c.providerPolicy!.sessionEstimatedTokens),
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
        PluginDefinition<TuiPluginContext>('tina/persistence',
            (c) => PersistencePlugin(openStore: c.openStore!),
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
            'tina/auto-compact', (c) => CompactionPlugin(terminal: c.terminal),
            description:
                'Summarizes older conversation history when context grows large to make room for more work.',
            live: true),
        PluginDefinition.dependingOn2<TuiPluginContext, ToolSessionSource,
                ModelAccess>('tina/subagents',
            first: toolProvider,
            second: modelAccess,
            create: (c, parentTools, models) => SubagentsPlugin(
                  config: SubagentsConfig(
                      maxDepth: c.limits.childDepth,
                      maxConcurrency: c.limits.childConcurrency,
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
