import 'dart:io';
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
    this.limits = const RequestLimits(),
  });
  final String workingDirectory;
  final String version;
  final ProviderPolicyPlugin? providerPolicy;
  final RequestLimits limits;
  final Terminal terminal;
  final ToolsPlugin tools;
  final ProviderFactory providerFactory;
  final String model;
  final SessionStoreOpener? openStore;
}

List<AgentPlugin> basePlugins(TuiPluginContext context) => [
      const PersonaPlugin(),
      if (context.providerPolicy != null) context.providerPolicy!,
      ModeCommandPlugin(mode: context.tools, terminal: context.terminal),
    ];

/// This catalog alone grants first-party names. Extension registration on
/// the returned registry rejects the reserved namespace.
PluginRegistry<TuiPluginContext> firstPartyPlugins() => PluginRegistry(
      liveFirstParty: {
        'tina/chat-tui',
        'tina/mode-tui',
        'tina/activity-tui',
        'tina/plans',
        'tina/goals',
        'tina/auto-compact',
        'tina/file-resources'
      },
      definitions: [
        updateTuiDefinition<TuiPluginContext>(),
        updateDefinition<TuiPluginContext>(
            version: (c) => c.version, terminal: (c) => c.terminal),
        approvalsDefinition<TuiPluginContext>(),
        approvalTuiDefinition<TuiPluginContext>(),
        PluginDefinition<TuiPluginContext>(
            'tina/approvals-stream', (_) => StreamApprovalChannel(),
            provides: [approvalChannel]),
        toolsDefinition<TuiPluginContext>((c) => c.tools),
      ],
      firstParty: {
        'tina/chat-tui': (c) => ChatTuiPlugin(
            model: c.model,
            tokenCap: c.limits.sessionTokens,
            showSessionId: c.openStore != null,
            sessionTokens: c.providerPolicy == null
                ? null
                : () => c.providerPolicy!.sessionTokens,
            sessionEstimatedTokens: c.providerPolicy == null
                ? null
                : () => c.providerPolicy!.sessionEstimatedTokens),
        'tina/mode-tui': (c) => ModeTuiPlugin(mode: c.tools),
        'tina/activity-tui': (c) =>
            ActivityTuiPlugin(terminal: c.terminal, printTranscript: false),
        'tina/persistence': (c) => PersistencePlugin(openStore: c.openStore!),
        'tina/plans': (c) => PlansPlugin(
              terminal: c.terminal,
              // Share the tools plugin's channel-independent approval service.
              approver: (request, reason) async =>
                  await c.tools.sandbox.approver?.call(request, reason) ??
                  Approval.no,
            ),
        'tina/goals': (c) => GoalsPlugin(terminal: c.terminal),
        'tina/auto-compact': (_) => CompactionPlugin(),
        'tina/subagents': (c) => SubagentsPlugin(
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
        'tina/file-resources': (c) => FileResourcesPlugin(
              config: FileResourcesConfig(
                directory: Directory('${c.workingDirectory}/.tina/skills').path,
                heading: '## Skills',
              ),
            ),
      },
    );
