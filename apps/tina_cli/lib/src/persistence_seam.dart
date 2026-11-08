/// The sqlite-backed persistence the native assembly links, behind a
/// seam (stage 5, engine-on-wasm): `dart:ffi` sqlite cannot compile to
/// wasm, where a composition root injects file-backed implementations
/// through [PersistenceWiring] instead — the same injection pattern the
/// app I/O and the tools factory use.
library;

import 'persistence_seam_unsupported.dart' if (dart.library.io) 'persistence_seam_io.dart';

export 'persistence_seam_unsupported.dart'
    if (dart.library.io) 'persistence_seam_io.dart';

/// Injected persistence wiring (a wasm composition root supplies
/// file-backed stores and replay); null means the platform default.
class PersistenceWiring {
  const PersistenceWiring({
    required this.openStore,
    required this.restoreSessionSettings,
    required this.storedSessionModel,
    this.closeStore,
  });

  /// Opens (creating parents) the session store at [path].
  final Object Function(String path) openStore;

  /// Replays a stored session's settings into the live settings.
  final void Function(Object settings, Object store, String sessionId)
      restoreSessionSettings;

  /// The stored session's model, when the store remembers one.
  final String? Function(Object store, String sessionId) storedSessionModel;

  /// Closes a store [openStore] returned (defaults to a no-op).
  final void Function(Object store)? closeStore;
}

PersistenceWiring? _injected;

/// The composition root's persistence wiring; null means the platform
/// default (sqlite natively, none under wasm).
set injectedPersistenceWiring(PersistenceWiring? wiring) => _injected = wiring;

/// Opens (creating parents) the session store at [path].
Object persistenceOpenStore(String path) =>
    _injected?.openStore(path) ?? nativePersistenceOpenStore(path);

/// Throws the store's "no such store" error (the session-listing path).
Never persistenceNoStore(String storePath) => nativePersistenceNoStore(storePath);

/// Lists one store's sessions: `id, entries, title` lines.
void persistenceListSessions(Object writer, String storePath) =>
    nativePersistenceListSessions(writer, storePath);

/// Replays a stored session's settings into the live [settings].
void restoreSessionSettings(Object settings, Object store, String sessionId) =>
    _injected != null
        ? _injected!.restoreSessionSettings(settings, store, sessionId)
        : nativeRestoreSessionSettings(settings, store, sessionId);

/// The stored session's model, when the store remembers one.
String? storedSessionModel(Object store, String sessionId) =>
    _injected != null
        ? _injected!.storedSessionModel(store, sessionId)
        : nativeStoredSessionModel(store, sessionId);

/// Whether [sessionId] has a stored session among [plugins].
bool sessionWasPersisted(Iterable<Object> plugins, String sessionId) =>
    nativeSessionWasPersisted(plugins, sessionId);

/// Closes a store [persistenceOpenStore] returned.
void closeStore(Object store) =>
    (_injected?.closeStore ?? nativeCloseStore)(store);
