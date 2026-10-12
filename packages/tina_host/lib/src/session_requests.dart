part of 'host.dart';

/// A host-issued retry namespace. Keep the whole ID when reconnecting; copying
/// its value into a newer window creates a different request and may repeat work.
final class SessionRequestWindow {
  const SessionRequestWindow(this.epoch, this.generation);
  final String epoch;
  final int generation;

  SessionRequestId id(String value) => SessionRequestId(this, value);
}

/// The caller chooses [value] (usually a UUID). Epoch and window come from the
/// host. Windows may expire under history pressure, even before first use.
final class SessionRequestId {
  const SessionRequestId(this.window, this.value);
  final SessionRequestWindow window;
  final String value;

  @override
  bool operator ==(Object other) =>
      other is SessionRequestId &&
      window.epoch == other.window.epoch &&
      window.generation == other.window.generation &&
      value == other.value;
  @override
  int get hashCode => Object.hash(window.epoch, window.generation, value);
}

enum SessionRequestState {
  accepted,
  running,
  completed,
  failed,
  cancelled,
  rejected
}

enum SessionRequestErrorCode { epochMismatch, expired, conflict, capacity }

/// Admission/retry errors never execute new work. Expiry means the host cannot
/// report the old result; it does not mean the operation never happened.
final class SessionRequestError implements Exception {
  const SessionRequestError(this.code);
  final SessionRequestErrorCode code;
  @override
  String toString() => switch (code) {
        SessionRequestErrorCode.epochMismatch =>
          'Request belongs to a different running session.',
        SessionRequestErrorCode.expired =>
          'Request history expired; execution will not be repeated.',
        SessionRequestErrorCode.conflict =>
          'Request ID was already used with different input.',
        SessionRequestErrorCode.capacity =>
          'Request capacity reached; all retained requests are still active.',
      };
}

/// Detached public state. [inputId] identifies the individual transcript turn;
/// [workId] is a cancellation target only while that work is active. A cancelled
/// command reports a cancellation request, not rollback of its side effects.
final class SessionRequestSnapshot {
  const SessionRequestSnapshot(this.id, this.state,
      {this.inputId, this.workId, this.result, this.resultTruncated = false});
  final SessionRequestId id;
  final SessionRequestState state;
  final String? inputId, workId;
  final SessionResult? result;
  final bool resultTruncated;
  bool get terminal =>
      state != SessionRequestState.accepted &&
      state != SessionRequestState.running;
}

/// Acceptance is synchronous and in memory. Completion is separate, read-only,
/// and survives connection close. Failed execution is a terminal snapshot, not
/// an unhandled future error when the submitting client has disconnected.
final class SessionRequest {
  SessionRequest._(this._record);
  final _RequestRecord _record;
  SessionRequestSnapshot get snapshot => _record.snapshot;
  Future<SessionRequestSnapshot> get completed => _record.done.future;
}

final class _RequestRecord {
  _RequestRecord(this.owner, this.id, this.text)
      : snapshot = SessionRequestSnapshot(id, SessionRequestState.accepted);
  final _SessionRequests owner;
  final SessionRequestId id;
  final String text;
  late final client = SessionRequest._(this);
  final done = Completer<SessionRequestSnapshot>();
  SessionRequestSnapshot snapshot;
  bool cancellationRequested = false;

  void setInput(String id) {
    snapshot = SessionRequestSnapshot(this.id, snapshot.state, inputId: id);
    owner.byInput[id] = this;
  }

  void start(String workId) {
    snapshot = SessionRequestSnapshot(id, SessionRequestState.running,
        inputId: snapshot.inputId, workId: workId);
    owner.host._changed();
  }

  void finish(SessionRequestState state, SessionResult result) {
    if (snapshot.terminal) return;
    // Receipts are bounded metadata, not another transcript or output store.
    const detailLimit = 16384;
    final truncated = result.detail.length > detailLimit;
    snapshot = SessionRequestSnapshot(id, state,
        inputId: snapshot.inputId,
        workId: snapshot.workId,
        result: truncated
            ? SessionResult(
                stopReason: result.stopReason,
                detail: result.detail.substring(0, detailLimit))
            : result,
        resultTruncated: truncated);
    owner.byInput.remove(snapshot.inputId);
    done.complete(snapshot);
    owner.host._changed();
  }
}

/// Bounded receipt metadata only. The engine owns every queued input; plugins
/// own command execution. Retained active records are never evicted. Evicting a
/// terminal record retires its namespace for all unknown IDs, so no tombstone
/// set, time-based guess, or unbounded client sequence table is needed.
final class _SessionRequests {
  _SessionRequests(this.host);
  final Host host;
  final records = <SessionRequestId, _RequestRecord>{};
  final byInput = <String, _RequestRecord>{};
  final byCommand = <String, _RequestRecord>{};
  int generation = 0;

  SessionRequestWindow get window =>
      SessionRequestWindow(host._epoch, generation);

  _RequestRecord? find(SessionRequestId id) {
    if (id.window.epoch != host._epoch) {
      throw const SessionRequestError(SessionRequestErrorCode.epochMismatch);
    }
    if (id.value.isEmpty ||
        id.value.length > 128 ||
        id.window.generation < 0 ||
        id.window.generation > generation) {
      throw ArgumentError('Invalid request ID or retry window');
    }
    final record = records[id];
    if (record != null) return record;
    if (id.window.generation != generation) {
      throw const SessionRequestError(SessionRequestErrorCode.expired);
    }
    return null;
  }

  _RequestRecord accept(SessionRequestId id, String text) {
    if (text.length > 1048576) {
      throw ArgumentError('Request input exceeds 1048576 characters');
    }
    if (records.length >= host.config.requestHistoryLimit) {
      final retired =
          records.values.where((r) => r.snapshot.terminal).firstOrNull;
      if (retired == null) {
        throw const SessionRequestError(SessionRequestErrorCode.capacity);
      }
      records.remove(retired.id);
      generation++;
    }
    final record = _RequestRecord(this, id, text);
    records[id] = record;
    host._changed();
    return record;
  }

  void settleInput(InputSettlement settlement) {
    final record = byInput[settlement.inputId];
    if (record == null) return;
    record.finish(
        switch (settlement.stopReason) {
          StopReason.complete => SessionRequestState.completed,
          StopReason.cancelled => SessionRequestState.cancelled,
          StopReason.error => SessionRequestState.failed,
        },
        SessionResult(
            stopReason: settlement.stopReason, detail: settlement.detail));
  }
}
