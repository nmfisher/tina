import 'package:tina_engine_2/tina_engine_2.dart';

/// The persona: who the agent is. The core owns no prompt text, so the
/// words live here, first section of every request.
final class PersonaPlugin extends AgentPlugin {
  const PersonaPlugin({this.id = 'tina/persona', this.order = 5});

  /// The session id for this plugin on the loop.
  @override
  final String id;

  /// Before the tools section, so the persona leads the prompt.
  @override
  final int order;

  @override
  void onPrompt(TurnContext c) =>
      c.promptSections.add('You are tina, a terminal coding agent.');
}
