/// One plugin interface for session lifecycle and turn phases. Turn phases
/// receive a `TurnContext` and assign what they want to change.
library;

import 'package:tina_core/tina_core.dart';

import 'context.dart';
import 'loop.dart';

/// A plugin. The core owns truth; the plugin owns decisions, made by
/// writing to the [TurnContext] it is handed.
///
/// Hooks are synchronous. Opening, mounting and turn phases run in ascending
/// [order], breaking ties by [id]; closing runs in reverse. The loop copies
/// the context before each turn phase: a throwing phase's writes are dropped.
/// Session lifecycle failures propagate to the host for resource cleanup.
abstract class AgentPlugin {
  /// Const: plugins are value-like config and can be const-constructed.
  const AgentPlugin();

  /// Lowercase publisher/name. The application reserves tina/ for first-party
  /// plugins. Duplicate IDs throw. Also the tie-breaker for [order].
  String get id;

  /// Ascending everywhere. Lower runs first.
  int get order => 100;

  /// Tools contributed to the loop. Snapshotted once per turn.
  List<ToolSchema> get tools => const [];

  /// Prepare session resources before constructing the loop. A plugin may
  /// return the restored transcript and details when resuming.
  SessionSeed? openSession(PluginSession session) => null;

  /// Persist or react to changes in the shared session metadata.
  void sessionChanged(PluginSession session) {}

  /// Release resources, including partially opened resources after a failure.
  void closeSession() {}

  /// Mount executors and subscribe to this session. Called once by the host.
  void mountOn(AgentLoop loop) {}

  /// Commands collected by the host; the loop does not dispatch them.
  List<Command> get commands => const [];

  /// Prompt section phase, before the turn: add a section to
  /// `c.promptSections`, or add nothing. The core owns the join; a plugin
  /// adds one section, never a whole prompt.
  void onPrompt(TurnContext c) {}

  /// Before the turn: the input is `c.input`; rewrite it by assignment.
  void onInput(TurnContext c) {}

  /// Before each model call: `c.messages`, `c.promptSections` and
  /// `c.pinnedTools` are the request about to be built.
  void beforeModelCall(TurnContext c) {}

  /// The guard: all must pass. Set `c.decision` to deny or ask; the
  /// default is already allow.
  void beforeToolCall(TurnContext c) {}

  /// After a tool ran: `c.toolResult` is what the executor returned;
  /// assign it to record a different result.
  void afterToolResult(TurnContext c) {}

  /// The turn ended: `c.outcome` is what the turn produced.
  void onTurnEnd(TurnContext c) {}
}
