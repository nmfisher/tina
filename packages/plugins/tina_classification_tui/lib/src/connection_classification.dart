import 'dart:async';
import 'package:tina_host/tina_host.dart';
import 'package:classification/observation.dart';

/// Classification display data, with no classifier or inference lease.
final class ConnectionClassificationObservation
    implements ClassificationObservation {
  ConnectionClassificationObservation(this._connection);
  final SessionConnection _connection;
  int _revision = -1;
  @override
  ClassificationStatus status = const ClassificationStatus(
    ClassificationPhase.idle,
  );
  @override
  ClassificationTraceSnapshot trace = ClassificationTraceSnapshot(
    revision: 0,
    exchanges: const [],
  );
  void _apply(SessionSnapshot snapshot) {
    if (snapshot.cursor.revision <= _revision) return;
    _revision = snapshot.cursor.revision;
    try {
      final data = snapshot.features['tina/classification'] as Map?;
      if (data == null) throw StateError('unavailable');
      status = ClassificationStatus(
        ClassificationPhase.values.byName(data['phase'] as String),
        inputId: data['input_id'] as String?,
        reason: data['reason'] as String?,
        result: data['result'] == null
            ? null
            : UtteranceClassification.fromJson(data['result'] as Map),
      );
      trace = ClassificationTraceSnapshot(
        revision: data['trace_revision'] as int,
        exchanges: (data['exchanges'] as List).cast<Map>().map(
          ClassificationExchangeSnapshot.fromJson,
        ),
      );
    } catch (_) {
      status = const ClassificationStatus(
        ClassificationPhase.unavailable,
        reason: 'classification details unavailable',
      );
      trace = ClassificationTraceSnapshot(
        revision: -snapshot.cursor.revision,
        exchanges: const [],
      );
    }
  }

  @override
  void Function() listen(void Function() changed) {
    final attachment = _connection.attach();
    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      attachment.close();
    }

    try {
      _apply(attachment.initial);
    } catch (_) {
      close();
      rethrow;
    }
    Future<void> observe() async {
      try {
        while (!closed) {
          final update = await attachment.next();
          if (closed || update == null) return;
          _apply(update.snapshot);
          changed();
          if (update.snapshot.status.closed) close();
        }
      } catch (_) {
        close();
      }
    }

    unawaited(observe());
    return close;
  }
}
