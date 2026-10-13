import 'dart:async';
import 'package:tina_host/tina_host.dart';
import 'package:tina_plans/observation.dart';

/// One view's plans projection. Closing a listener leaves the session running.
final class ConnectionPlanObservation implements PlanObservation {
  ConnectionPlanObservation(this._connection);
  final SessionConnection _connection;
  int _revision = -1;
  @override
  PlanState state = PlanState(items: const []);
  @override
  String? unavailableReason;
  void _apply(SessionSnapshot snapshot) {
    if (snapshot.cursor.revision <= _revision) return;
    _revision = snapshot.cursor.revision;
    try {
      final data = snapshot.features['tina/plans'] as Map?;
      if (data == null || snapshot.historyPublicationFailed)
        throw StateError('unavailable');
      final plan =
          PlanChangedEntry.fromJson(Map<String, dynamic>.from(data), '', 0);
      state = PlanState(items: plan.items, approval: plan.approval);
      unavailableReason = null;
    } catch (_) {
      state = PlanState(items: const []);
      unavailableReason = 'Plan unavailable';
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
