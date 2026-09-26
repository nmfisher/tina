/// One plugin interface. Every hook has a default that does nothing, so a
/// plugin implements only what it needs.
library;

import 'context.dart';
import 'model.dart';

/// A plugin. The core owns truth; the plugin owns decisions.
///
/// All hooks are sync. The loop runs them in ascending [order], breaking
/// ties by [id], so the sequence is the same every run.
abstract class AgentPlugin {
  /// Unique. Registering a duplicate id throws. Tie-breaker for [order].
  String get id;

  /// Ascending everywhere. Lower runs first.
  int get order => 100;

  /// Tools contributed to the loop. Snapshotted once per turn.
  List<Tool> get tools => const [];

  /// A prompt section, or null for none. Called once per turn, in order.
  /// The core owns the join; a plugin returns one section, never a prompt.
  String? systemSection(Context c) => null;

  /// First hook of a turn. Returns a replacement input or null.
  Input? beforeInvocation(Context c, Input input) => null;

  /// Runs before every model call. Returns a replacement request or null.
  /// This is the seam for pruning and redaction plugins.
  Request? beforeRequest(Context c, Request request) => null;

  /// The guard. All guards must pass; [order] decides who reports first.
  Decision beforeTool(Context c, ToolCall call) => const Decision.allow();

  /// After a tool result exists. Return a replacement to record it instead,
  /// or null to observe only.
  Object? afterTool(Context c, ToolResult result) => null;

  /// The turn ended. Return value ignored. For metrics and logging.
  void onTurnEnd(Context c, Outcome outcome) {}
}
