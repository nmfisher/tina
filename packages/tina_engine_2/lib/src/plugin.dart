/// One plugin interface. Every phase is a `TurnContext` in, nothing out:
/// the plugin reads what it needs and assigns what it wants to change.
library;

import 'package:tina_core/tina_core.dart';

import 'context.dart';

/// A plugin. The core owns truth; the plugin owns decisions, made by
/// writing to the [TurnContext] it is handed.
///
/// All hooks are sync and run in ascending [order], breaking ties by [id],
/// so the sequence is the same every run. The loop copies the context
/// before every call: a plugin that throws has its copy dropped and the
/// turn continues — a throwing phase's writes never arrive.
abstract class AgentPlugin {
  /// Const: plugins are value-like config and can be const-constructed.
  const AgentPlugin();

  /// Unique. Registering a duplicate id throws. Tie-breaker for [order].
  String get id;

  /// Ascending everywhere. Lower runs first.
  int get order => 100;

  /// Tools contributed to the loop. Snapshotted once per turn.
  List<ToolSchema> get tools => const [];

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
