part of 'host.dart';

/// Registered by a plugin's definition, invoked only by the session owner.
typedef SessionOperationHandler = Future<SessionResult> Function(
    AgentPlugin plugin,
    Map<String, Object?> arguments,
    SessionOperationContext context);

typedef SessionControlHandler = SessionResult Function(
    AgentPlugin plugin, Map<String, Object?> arguments);

/// A foreground operation owns the session until its future settles. A control
/// is synchronous, cannot start turns, and may opt into running alongside work.
/// Scheduling belongs to the plugin declaration, never to client arguments.
final class SessionOperation {
  const SessionOperation(SessionOperationHandler handler)
      : handler = handler,
        control = null,
        allowWhileRunning = false;
  const SessionOperation.control(SessionControlHandler control,
      {this.allowWhileRunning = false})
      : control = control,
        handler = null;
  final SessionOperationHandler? handler;
  final SessionControlHandler? control;
  final bool allowWhileRunning;
}

/// Capabilities valid only for this invocation. Cancellation spans every turn
/// and between-turn work; closing a client connection does not cancel it.
final class SessionOperationContext {
  SessionOperationContext._(this._host, this._record, this._scope, this._work);
  final Host _host;
  final _RequestRecord _record;
  final QuestionScope _scope;
  final SessionWork _work;
  final _cancel = CancelToken();

  /// Shared with owner-side work that needs synchronous cancellation checks.
  /// Client connections never receive this token.
  CancelToken get cancellation => _cancel;
  bool _active = true;
  bool _sending = false;
  Completer<void>? _turnSettled;
  bool get cancelled => _cancel.cancelled;
  Future<void> get whenCancelled => _cancel.whenCancelled;

  void _checkActive() {
    if (!_active || cancelled)
      throw StateError('Operation is no longer active');
  }

  Future<Outcome> send(String text) async {
    _checkActive();
    if (_sending) throw StateError('An operation turn is already running');
    _sending = true;
    final settled = _turnSettled = Completer<void>();
    try {
      return await _host._send(text);
    } finally {
      _sending = false;
      settled.complete();
    }
  }

  void writeLine(String text, {bool error = false}) {
    _checkActive();
    _record.writeOutput(text, error: error);
  }

  void _stop(String reason) {
    if (!_active && !_sending) return;
    _cancel.cancel(reason);
    _scope.cancel();
    if (_sending) {
      _host._turnQuestions?.cancel();
      _host.session.loop.cancel(reason);
    }
  }
}

/// Ephemeral operation output, bounded per retained receipt. Full conversation
/// history remains in the session log. Sequence numbers detect missed output.
final class SessionOutput {
  const SessionOutput(this.seq, this.text,
      {this.error = false, this.truncated = false});
  final int seq;
  final String text;
  final bool error, truncated;
}

final class SessionOutputPage {
  SessionOutputPage(
      Iterable<SessionOutput> entries, this.throughSeq, this.missed)
      : entries = List.unmodifiable(entries);
  final List<SessionOutput> entries;
  final int throughSeq;
  final bool missed;
}

// Canonical JSON makes retries independent of map insertion order. Reject live
// objects and non-string keys rather than calling user-defined toJson methods.
Object? _operationValue(Object? value, [int depth = 0]) {
  if (depth > 64)
    throw ArgumentError('Operation arguments are too deeply nested');
  if (value == null || value is String || value is bool || value is int)
    return value;
  if (value is double && value.isFinite) return value;
  if (value is List)
    return List.unmodifiable(
        value.map((item) => _operationValue(item, depth + 1)));
  if (value is Map && value.keys.every((key) => key is String)) {
    final keys = value.keys.cast<String>().toList()..sort();
    return Map<String, Object?>.unmodifiable({
      for (final key in keys) key: _operationValue(value[key], depth + 1),
    });
  }
  throw ArgumentError('Operation arguments must contain only JSON values');
}
