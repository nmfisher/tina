part of 'host.dart';

/// A cursor is meaningful only within one running host, including on resume.
final class SessionCursor {
  const SessionCursor(this.epoch, this.revision);
  final String epoch;
  final int revision;
}

/// Complete current attachment state. History is paged separately through
/// [throughSeq], never copied into each progress update. Feature values are
/// detached public data supplied by their owners, not a second durable store.
final class SessionSnapshot {
  SessionSnapshot._(
      this.cursor,
      this.status,
      this.throughSeq,
      this.historyPublicationFailed,
      Iterable<Input> inputs,
      Iterable<SessionRequestSnapshot> requests,
      Iterable<SessionWork> work,
      Iterable<SessionQuestion> questions,
      Iterable<String> plugins,
      Map<String, Object?> features,
      Iterable<String> unavailableFeatures,
      Map<String, Object?> tools)
      : pendingInputs = List.unmodifiable(inputs),
        requests = List.unmodifiable(requests),
        activeWork = List.unmodifiable(work),
        questions = List.unmodifiable(questions),
        plugins = List.unmodifiable(plugins),
        features = Map.unmodifiable(features),
        unavailableFeatures = List.unmodifiable(unavailableFeatures),
        activeTools = freezeSnapshotValue(tools) as Map<String, Object?>;
  final SessionCursor cursor;
  final SessionStatus status;

  /// Last contiguous entry successfully published to synchronous subscribers.
  /// With persistence installed, its writes finish before this watermark moves.
  final int throughSeq;
  final bool historyPublicationFailed;
  final List<Input> pendingInputs;

  /// Bounded request receipts; use the original ID to query or retry. Missing
  /// receipts are not evidence that an operation was never executed.
  final List<SessionRequestSnapshot> requests;
  final List<SessionWork> activeWork;
  final List<SessionQuestion> questions;
  final List<String> plugins, unavailableFeatures;
  final Map<String, Object?> features, activeTools;
}

final class SessionHistoryPage {
  SessionHistoryPage._(this.epoch, this.throughSeq, this.nextAfterSeq,
      this.hasMore, Iterable<Map<String, Object?>> entries)
      : entries = List.unmodifiable(entries);
  final String epoch;
  final int throughSeq, nextAfterSeq;
  final bool hasMore;
  final List<Map<String, Object?>> entries;
}

/// Every update replaces current state. When [coalesced] is true, intermediate
/// transient states were replaced; read missing durable history from the log
/// through the new watermark. Applying snapshots never appends preview text.
final class SessionUpdate {
  const SessionUpdate(this.snapshot, {required this.coalesced});
  final SessionSnapshot snapshot;
  final bool coalesced;
}

/// A bounded pull subscription, registered atomically with [initial]. Each
/// attachment retains at most one unread replacement. Paused consumers cannot
/// accumulate a StreamController queue. Closing settles an outstanding read
/// without cancelling session work or resolving interactions.
final class SessionAttachment {
  SessionAttachment._(this._connection, this.initial)
      : _lastOffered = initial.cursor.revision;
  final SessionConnection _connection;
  final SessionSnapshot initial;
  SessionUpdate? _pending;
  Completer<SessionUpdate?>? _waiting;
  bool _closed = false;
  int _lastOffered;
  int get bufferedUpdates => _pending == null ? 0 : 1;

  Future<SessionUpdate?> next() {
    if (_waiting != null)
      throw StateError('Only one attachment read at a time');
    if (_closed) return Future.value(null);
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      return Future.value(pending);
    }
    return (_waiting = Completer<SessionUpdate?>()).future;
  }

  void _offer(SessionSnapshot snapshot) {
    if (_closed || snapshot.cursor.revision <= _lastOffered) return;
    _lastOffered = snapshot.cursor.revision;
    final waiter = _waiting;
    if (waiter != null) {
      _waiting = null;
      waiter.complete(SessionUpdate(snapshot, coalesced: false));
    } else {
      _pending = SessionUpdate(snapshot, coalesced: _pending != null);
    }
  }

  SessionHistoryPage history(
      {required SessionSnapshot snapshot, int afterSeq = -1, int limit = 128}) {
    if (_closed) throw StateError('Attachment is closed');
    return _connection.history(
        snapshot: snapshot, afterSeq: afterSeq, limit: limit);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _pending = null;
    _waiting?.complete(null);
    _waiting = null;
    _connection._attachments.remove(this);
  }
}

final class _FeatureObservation {
  _FeatureObservation(this.source, this.release);
  final SnapshotFeature source;
  final void Function() release;
}
