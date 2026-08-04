import '../agent/sub_agent_scheduler.dart';
import 'tool.dart';

/// Optional hook that builds a nested `delegate` tool for a sub-agent that is
/// allowed to spawn further sub-agents. Set by the wiring to enable nesting;
/// null means sub-agents can't delegate. Takes the full [AgentToolContext] the
/// scheduler assembles for the nested agent, so the wiring is a one-liner
/// (`(ctx) => DelegateTool(ctx)`).
///
/// Lives in its own neutral file so the delegation wiring type is importable
/// without pulling in tool implementations. (It necessarily references
/// [AgentToolContext], which is defined in `sub_agent_scheduler.dart`.)
typedef NestedDelegateToolBuilder = Tool Function(AgentToolContext ctx);
