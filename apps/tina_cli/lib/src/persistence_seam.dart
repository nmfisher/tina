/// The sqlite-backed persistence the native assembly links, behind a
/// seam (stage 5, engine-on-wasm): `dart:ffi` sqlite cannot compile to
/// wasm, where persistence is simply absent — the config selects no
/// `tina/persistence` plugin and resume is refused.
library;

import 'persistence_seam_unsupported.dart' if (dart.library.io) 'persistence_seam_io.dart';

export 'persistence_seam_unsupported.dart'
    if (dart.library.io) 'persistence_seam_io.dart';

/// Opens (creating parents) the session store at [path].
Object persistenceOpenStore(String path) => nativePersistenceOpenStore(path);

/// Throws the store's "no such store" error (the session-listing path).
Never persistenceNoStore(String storePath) => nativePersistenceNoStore(storePath);

/// Lists one store's sessions: `id, entries, title` lines.
void persistenceListSessions(Object writer, String storePath) =>
    nativePersistenceListSessions(writer, storePath);

/// Replays a stored session's settings into the live [settings].
void restoreSessionSettings(Object settings, Object store, String sessionId) =>
    nativeRestoreSessionSettings(settings, store, sessionId);

/// The stored session's model, when the store remembers one.
String? storedSessionModel(Object store, String sessionId) =>
    nativeStoredSessionModel(store, sessionId);

/// Whether [sessionId] has a stored session among [plugins].
bool sessionWasPersisted(Iterable<Object> plugins, String sessionId) =>
    nativeSessionWasPersisted(plugins, sessionId);

/// Closes a store [persistenceOpenStore] returned.
void closeStore(Object store) => nativeCloseStore(store);
