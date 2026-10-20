import 'dart:async';

import 'package:tina_host/tina_host.dart';
import 'package:tina_tasks/tina_tasks.dart';

/// Task queue display data, read from the session snapshot's
/// `tina/tasks` feature (the plugin's public projection). No store or
/// engine access lives here — the connection hands us JSON only.
final class ConnectionTaskObservation implements TaskObservation {
  ConnectionTaskObservation(this._connection);
  final SessionConnection _connection;
  int _revision = -1;
  bool _unavailable = false;

  @override
  TaskState state = TaskState(items: []);

  void _apply(SessionSnapshot snapshot) {
    if (snapshot.cursor.revision <= _revision) return;
    _revision = snapshot.cursor.revision;
    try {
      final data = snapshot.features['tina/tasks'] as Map?;
      if (data == null) throw StateError('unavailable');
      final rawItems = data['items'];
      if (rawItems is! List) throw StateError('bad items');
      final items = <TaskEntryItem>[
        for (final raw in rawItems)
          TaskEntryItem(
            id: (raw as Map)['id'] as String,
            text: raw['text'] as String,
            state: raw['state'] as String? ?? 'pending',
            summary: raw['summary'] as String? ?? '',
          ),
      ];
      state = TaskState(items: items);
      _unavailable = false;
    } catch (_) {
      _unavailable = true;
      state = TaskState(items: []);
    }
  }

  @override
  String? get unavailableReason => _unavailable ? 'task queue unavailable' : null;

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
