/// Circuit breaker for identical failing tool calls.
///
/// Observed live: a model re-issued one tool call — same tool, same
/// arguments — many times in a single turn, each attempt failing with the
/// same deterministic error, and kept doing so even after acknowledging a
/// user's instruction to stop. The loop had no memory of identical failing
/// calls; this file is that memory.
///
/// One breaker per turn: the loop creates it when the turn starts, so a
/// new turn starts every counter at zero. The constants below are loop
/// policy, deliberately hardcoded — there is no settings surface for them.
library;

import 'dart:convert';
import 'dart:collection';

import 'package:tina_core/tina_core.dart';

/// How many consecutive identical failures (same tool, same canonical
/// arguments, same error) before the next identical call is blocked
/// without executing.
const int breakerFailuresToBlock = 2;

/// After the first blocked call, how many further unchanged retries the
/// model gets before the turn is stopped. Two: one retry the model should
/// learn from, a second that proves it will not.
const int breakerBlockedRetriesToStop = 2;

typedef _CallKey = (String, String);

final class _Streak {
  _Streak(this.key, this.error);
  final _CallKey key;
  final String error;
  int failures = 1;

  /// Blocked attempts: calls refused without executing. The first carries
  /// the breaker message; the ones after it are the retries that count
  /// toward the hard stop.
  int blocked = 0;
}

/// Remembers identical failing tool calls for one turn.
///
/// The key is the tool name plus the canonical form of the arguments:
/// object keys sorted recursively and serialized as compact JSON, so the
/// encoding carries no insignificant whitespace (JCS-style). String values
/// compare exactly — only argument *structure* is normalized, never the
/// data inside it.
///
/// Only executed calls are remembered. An attempt the loop never ran —
/// denied, cancelled, skipped, already blocked — has no outcome to
/// compare and does not touch the state. Any executed call with a
/// different key (changed arguments or a different tool) replaces the
/// streak, which is how the counter resets.
final class ToolCallBreaker {
  _Streak? _streak;

  /// The canonical argument form: keys sorted recursively, compact JSON.
  static String canonicalArguments(Map<String, Object?> input) =>
      jsonEncode(_normalize(input));

  static Object? _normalize(Object? value) {
    if (value is Map) {
      final sorted = SplayTreeMap<String, Object?>();
      for (final entry in value.entries) {
        sorted[entry.key.toString()] = _normalize(entry.value);
      }
      return sorted;
    }
    if (value is List) return [for (final item in value) _normalize(item)];
    return value;
  }

  static _CallKey _key(String tool, Map<String, Object?> input) =>
      (tool, canonicalArguments(input));

  /// Record an executed call's outcome. A success clears the streak. An
  /// error extends it when both the call and the error text match; any
  /// other outcome — different key, or the same key failing differently —
  /// starts a fresh streak of one.
  void recordExecution(
      String tool, Map<String, Object?> input, ToolResult result) {
    final key = _key(tool, input);
    if (!result.isError) {
      _streak = null;
      return;
    }
    final streak = _streak;
    if (streak != null && streak.key == key && streak.error == result.content) {
      streak.failures++;
      return;
    }
    _streak = _Streak(key, result.content);
  }

  /// Whether this exact call should be refused without executing.
  bool blocks(String tool, Map<String, Object?> input) {
    final streak = _streak;
    return streak != null &&
        streak.key == _key(tool, input) &&
        streak.failures >= breakerFailuresToBlock;
  }

  /// Register one refused attempt. Returns the hard-stop notice when the
  /// model has retried the blocked call once too often and the turn must
  /// end; null while the breaker message is still the only response.
  String? registerBlocked(String tool, Map<String, Object?> input) {
    final streak = _streak!;
    streak.blocked++;
    if (streak.blocked <= breakerBlockedRetriesToStop) return null;
    return 'tool-call breaker: the agent repeated a failing call and was '
        'stopped. Tool "${streak.key.$1}" failed ${streak.failures} times '
        'with the same error, then was retried unchanged ${streak.blocked} '
        'more times without executing. Last error: "${streak.error}"';
  }

  /// The tool result for a refused call: what the model reads instead of
  /// an execution.
  String blockedMessage(String tool, Map<String, Object?> input) {
    final streak = _streak!;
    return 'not executed: this exact call — tool "$tool", arguments '
        '${canonicalArguments(input)} — has failed ${streak.failures} times '
        'with the same error: "${streak.error}". It will not run again '
        'unchanged. Change the arguments, use a different approach, or '
        'explain the blocker to the user.';
  }
}
