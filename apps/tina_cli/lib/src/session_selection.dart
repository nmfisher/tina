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

/// A command the user can paste into their shell after terminal restoration.
/// Explicit paths are absolute so it also works from a different directory.
String sessionResumeCommand({
  required String sessionId,
  String? workingDirectory,
  String? configPath,
  String? storePath,
  String? backend,
}) => [
  'tina',
  '--resume',
  sessionId,
  if (workingDirectory != null) ...[
    '--cwd',
    Directory(workingDirectory).absolute.path,
  ],
  if (configPath != null) ...['--config', File(configPath).absolute.path],
  if (storePath != null) ...['--store', File(storePath).absolute.path],
  if (backend != null) ...['--backend', backend],
].map(_shellArgument).join(' ');

String _shellArgument(String value) =>
    RegExp(r'^[a-zA-Z0-9_@%+=:,./-]+$').hasMatch(value)
    ? value
    : "'${value.replaceAll("'", "'\"'\"'")}'";
