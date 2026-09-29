import 'dart:io';

import 'package:tina_persistence/tina_persistence.dart';

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

/// A line-based picker before the full-screen terminal starts. Blank input,
/// q and EOF cancel without starting an agent or contacting a provider.
String? pickSession(
  List<StoredSession> sessions, {
  required String? Function() readLine,
  required void Function(String) writeLine,
}) {
  for (var i = 0; i < sessions.length; i++) {
    final s = sessions[i];
    // Persisted titles must not inject terminal control sequences.
    final title =
        (s.title ?? '').replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
    final id = s.id.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
    writeLine(
        '${i + 1}. $id  ${s.entries} entries${title.isEmpty ? '' : '  $title'}');
  }
  while (sessions.isNotEmpty) {
    writeLine('Select session [1-${sessions.length}], or Enter/q to cancel:');
    final answer = readLine()?.trim();
    if (answer == null || answer.isEmpty || answer.toLowerCase() == 'q') {
      return null;
    }
    final number = int.tryParse(answer);
    if (number != null && number >= 1 && number <= sessions.length) {
      return sessions[number - 1].id;
    }
    writeLine('Enter a number from 1 to ${sessions.length}.');
  }
  return null;
}
