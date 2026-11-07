import 'package:tina_persistence/tina_persistence.dart';

import 'package:tina_settings/tina_settings.dart';

import 'assembly.dart' show AssemblyWriter;

/// The native persistence over sqlite (see `persistence_seam.dart`).
Object nativePersistenceOpenStore(String path) {
  final store = SessionStore.open(path);
  return store;
}

Never nativePersistenceNoStore(String storePath) =>
    throw SessionStoreException('no session store at $storePath');

void nativePersistenceListSessions(Object writer, String storePath) {
  final store = SessionStore.open(storePath);
  try {
    final sessions = store.list();
    if (sessions.isEmpty) {
      (writer as AssemblyWriter).writeln('no sessions in $storePath');
      return;
    }
    for (final s in sessions) {
      (writer as AssemblyWriter).writeln('${s.id}  ${s.entries} entries'
          '${s.title == null ? '' : '  ${s.title}'}');
    }
  } finally {
    store.close();
  }
}

void nativeRestoreSessionSettings(Object settings, Object store, String sessionId) {
  PersistencePlugin.restoreSettings(
      settings as ScopedSettings, (store as SessionStore).readEntries(sessionId));
}

String? nativeStoredSessionModel(Object store, String sessionId) =>
    (store as SessionStore)
        .list()
        .singleWhere((s) => s.id == sessionId)
        .model;

bool nativeSessionWasPersisted(Iterable<Object> plugins, String sessionId) =>
    plugins
        .whereType<PersistencePlugin>()
        .any((plugin) => plugin.store.list().any((row) => row.id == sessionId));

void nativeCloseStore(Object store) => (store as SessionStore).close();
