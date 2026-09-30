import 'package:tina_engine_2/tina_engine_2.dart';

/// The system instruction: who the agent is. The core owns no prompt text, so the
/// words live here, first section of every request.
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
  void onPrompt(TurnContext c) =>
      c.promptSections.add('You are tina, a terminal coding agent.');
}
