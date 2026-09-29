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
import 'package:tina_persona/tina_persona.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_plans/tina_plans.dart';
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
  final SessionStoreOpener? openStore;
}

/// Required host plugins also carry metadata, without becoming optional features.
List<PluginDefinition<TuiPluginContext>> basePluginDefinitions() => [
      PluginDefinition('tina/persona', (_) => const PersonaPlugin(),
          description:
              'Supplies the agent identity and base instructions for conversations.'),
      PluginDefinition('tina/providers', (c) => c.providerPolicy!,
          description:
              'Connects configured models and providers and enforces request and token limits.'),
      PluginDefinition('tina/mode', (c) {
        final policy = c.tools.modePolicy;
        policy.terminal = c.terminal;
        policy.classifier = PermissionClassifier(() =>
            c.providerPolicy?.mainProvider(c.model) ??
            c.providerFactory(c.model));
        return ModeTuiPlugin(policy: policy);
      },
          description:
              'Owns ask, read-only, allow-edits and auto permissions, with /mode and Shift-Tab selection.'),
    ];

List<AgentPlugin> basePlugins(TuiPluginContext context) => [
      for (final definition in basePluginDefinitions())
        if (definition.id != 'tina/providers' || context.providerPolicy != null)
          definition.build(context, const []),
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
      definitions: [
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
        toolsDefinition<TuiPluginContext>((c) => c.tools),
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
        PluginDefinition<TuiPluginContext>(
            'tina/plans',
            (c) => PlansPlugin(
                  terminal: c.terminal,
                  // Plan consent is always human, never a tool-safety judgment.
                  approver: (request, reason) async {
                    final decision =
                        await c.tools.modePolicy.approvals?.request(
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
            'tina/auto-compact', (_) => CompactionPlugin(),
            description:
                'Summarizes older conversation history when context grows large to make room for more work.',
            live: true),
        PluginDefinition<TuiPluginContext>(
            'tina/subagents',
            (c) => SubagentsPlugin(
                  config: SubagentsConfig(
                      maxDepth: c.limits.childDepth,
                      maxConcurrency: c.limits.childConcurrency,
                      tokenBudget: 0),
                  sessionFactory: standardChildFactory(
                    parentTools: c.tools,
                    providerFactory: c.providerFactory,
                    model: c.model,
                    childPlugins: () => [
                      const PersonaPlugin(),
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
