/// The no-`dart:ffi` persistence: none exists under wasm; reaching it is
/// a wiring bug (the config must not select persistence there).
Object nativePersistenceOpenStore(String path) => throw UnsupportedError(
    'no sqlite persistence on this platform: the config must not select it');

Never nativePersistenceNoStore(String storePath) => throw UnsupportedError(
    'no sqlite persistence on this platform: nothing to list');

void nativePersistenceListSessions(Object writer, String storePath) =>
    throw UnsupportedError(
        'no sqlite persistence on this platform: nothing to list');

void nativeRestoreSessionSettings(Object settings, Object store, String sessionId) =>
    throw UnsupportedError('no sqlite persistence on this platform');

String? nativeStoredSessionModel(Object store, String sessionId) =>
    throw UnsupportedError('no sqlite persistence on this platform');

bool nativeSessionWasPersisted(Iterable<Object> plugins, String sessionId) => false;

void nativeCloseStore(Object store) {}
