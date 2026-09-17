import 'package:tina_engine/tina_engine.dart';

import '../workflows/ask_user_tool.dart';
import '../exploration/explore_project_tool.dart';

/// Independent of permission mode: approvals must not widen an orchestrator's
/// capabilities. This is opt-in for conversations dedicated to exploration.
enum AgentToolAccess { standard, orchestrator }

const _explorationTurnPrefix = 'Tina implementation exploration request:\n';

/// Slash-command turns use the normal conversation lifecycle and recorder.
String explorationTurnPrompt(String question) =>
    '$_explorationTurnPrefix${question.trim()}\n\n'
    'Use explore_project to filter the repository for this question. You have no '
    'direct filesystem or shell access for this turn. Use auto mode normally; '
    'verify requests content judgments and rank returns names only. Explain the '
    'actual source excerpts returned by the tool, citing their paths and line '
    'ranges. Candidate name scores are not implementation evidence. Unverified '
    'source is available for your own analysis; do not claim Typesafe verified it. '
    'Region scores do not describe unseen file content. Report remaining gaps; '
    'do not invent locations or details absent from the excerpts.';

ToolRegistry? explorationToolsForTurn(ToolRegistry base, String prompt) {
  if (!prompt.startsWith(_explorationTurnPrefix)) return null;
  final explore = base['explore_project'];
  final ask = base['ask_user'];
  return orchestratorTools(
    ask is AskUserTool ? ask : AskUserTool(null),
    exploreProject: explore is ExploreProjectTool ? explore : null,
  );
}

/// Build from vetted concrete tools, not a name-filtered plugin registry.
/// No generic delegate/launch_workflow/channel/summary tools: those are indirect
/// routes to filesystem access. Only the concrete bounded exploration tool
/// may collect evidence on behalf of this role.
ToolRegistry orchestratorTools(
  AskUserTool askUser, {
  ExploreProjectTool? exploreProject,
}) => _OrchestratorRegistry(askUser, exploreProject);

class OrchestratorToolGuard implements ToolGuard {
  const OrchestratorToolGuard();

  @override
  String? block(String toolName, Map<String, dynamic> input) =>
      toolName == 'ask_user' || toolName == 'explore_project'
      ? null
      : 'This orchestrator cannot access filesystem or general execution tools. '
            'Use the bounded scout workflow for repository evidence.';
}

class _OrchestratorRegistry extends ToolRegistry {
  _OrchestratorRegistry(AskUserTool askUser, ExploreProjectTool? exploreProject)
    : super([askUser, if (exploreProject != null) exploreProject]);

  @override
  String? executionBlock(String name, Map<String, dynamic> input) =>
      const OrchestratorToolGuard().block(name, input);
}
