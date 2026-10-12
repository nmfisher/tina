import 'dart:io';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tui/tina_tui.dart' show SessionChoice;

/// Main sessions in local activity order. Reading absent history never creates
/// a store, and child sessions cannot accidentally become the next CLI session.
List<StoredSession> resumableSessions(String path) {
  if (!File(path).existsSync()) {
    throw SessionStoreException('no session store at $path');
  }
  final store = SessionStore.open(path);
  try {
    return store.list().where((s) => (s.details?.depth ?? 0) == 0).toList()
      ..sort((a, b) => b.lastActivityKey.compareTo(a.lastActivityKey));
  } finally {
    store.close();
  }
}

List<SessionChoice> sessionChoices(Iterable<StoredSession> sessions) => [
  for (final session in sessions)
    SessionChoice(
      id: session.id,
      entries: session.entries,
      title: session.title,
      summary: session.summary,
      model: session.model,
      lastSavedAt: session.lastSavedAt,
    ),
];
