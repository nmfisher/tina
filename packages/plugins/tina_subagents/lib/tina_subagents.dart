/// tina_subagents — sub-agents as a plugin.
///
/// A sub-agent is a **child session**: its own provider from the
/// factory, its own log, the parent's working directory and mode, and a
/// restricted plugin set (tools, but no sub-agents and no persistence).
/// This package contributes the plugin and two tools: `launch_subagent`
/// launches a child in the background and returns immediately with its
/// id (non-blocking), and `subagent` inspects it (`status`), joins it
/// (`wait`), or stops it (`cancel`).
///
/// Every limit is enforced in the plugin — depth above the maximum,
/// concurrency at the maximum, the token budget exhausted — and each
/// refusal is a normal tool result naming the limit it hit. Never a
/// throw past the loop, never a silent skip.
library;

export 'src/child_assembly.dart';
export 'src/spawn_tool.dart';
export 'src/subagents_plugin.dart';
export 'src/settings.dart';
