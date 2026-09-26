/// Turn bookkeeping: what the turn appended, what the model saw, and the
/// `onTurnEnd` fan-out. Split out of loop.dart so the loop file stays close
/// to the five steps.
library;

import 'context.dart';
import 'model.dart';
import 'plugin.dart';

/// Accumulates one turn's outputs and builds the final [Outcome].
final class TurnRecorder {
  TurnRecorder(this._pinnedTools, this._snapshot, this._pluginsInOrder);

  final List<Tool> _pinnedTools;
  final Context Function(List<Tool> pinned) _snapshot;
  final List<AgentPlugin> Function() _pluginsInOrder;

  final List<Message> appended = [];
  final List<Request> requests = [];
  final List<Message> responses = [];
  String? changedBy;

  /// Build the outcome and fan out `onTurnEnd`. A throwing listener is
  /// isolated: the others still get the event.
  Outcome finish(StopReason reason, String detail, CancelToken cancel) {
    final outcome = Outcome(
        stopReason: reason,
        messages: [for (final m in appended) m.copy()],
        modelRequests: [for (final r in requests) r.snapshot()],
        modelResponses: [for (final m in responses) m.copy()],
        usage: responses.length,
        detail: detail,
        changedBy: changedBy);
    for (final p in _pluginsInOrder()) {
      try {
        p.onTurnEnd(_snapshot(_pinnedTools), outcome);
      } catch (_) {
        // one bad plugin must not break the turn end
      }
    }
    return outcome;
  }
}
