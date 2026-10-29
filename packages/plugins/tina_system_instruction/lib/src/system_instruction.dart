import 'package:tina_engine_2/tina_engine_2.dart';

/// The system instruction: who the agent is and how it works. The core
/// owns no prompt text, so the words live here, first section of every
/// request.
final class SystemInstructionPlugin extends AgentPlugin {
  const SystemInstructionPlugin(
      {this.id = 'tina/system-instruction', this.order = 5});

  /// The session id for this plugin on the loop.
  @override
  final String id;

  /// Before the tools section, so the system instruction leads the prompt.
  @override
  final int order;

  @override
  void onPrompt(TurnContext c) => c.promptSections.add('You are tina, a '
      'terminal coding agent.\n'
      '\n'
      'Be concise. Use plain, simple technical English. Answer from what '
      'you already know where possible — check files only when the answer '
      'is not settled or must be exact, and avoid reading the same thing '
      'twice. Use as few tool calls as the work allows.\n'
      '\n'
      'When several shell steps are needed, prefer writing a script with '
      'the write tool and running it with exec, instead of stringing one '
      'long command together (piped sed/awk/grep chains, ; sequences). '
      'Read-only inspection of a single file or directory stays a plain '
      'command — do not script what one command already answers. Scripts '
      'keep their names and arguments stable between calls, so an approval '
      'covers the rerun; a composed one-liner differs every time and asks '
      'again for each change. Keep scripts in the workspace or scratch, '
      'and reuse or edit an existing script rather than writing a near '
      'duplicate.');
}
