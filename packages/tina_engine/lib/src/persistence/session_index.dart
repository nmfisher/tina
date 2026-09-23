import 'session_store.dart';
import 'jsonl_session_store.dart';

/// Read-only startup view of saved sessions.
///
/// The pre-runtime paths — the resume picker, `--resume`'s cwd restore, and
/// `--list` — must read saved sessions before any plugin runtime exists, so
/// they cannot resolve the store from scope ([sessionStoreServiceKey]). This
/// interface is what they depend on instead: exactly the two reads startup
/// needs, nothing that can write or own lifecycle.
///
/// [listSessions] mirrors [SessionStore.listSessions]; [cwdFor] is the
/// read-only equivalent of the launcher's `resumeCwdFor` helper.
abstract interface class SessionIndex {
  /// List sessions with metadata, most-recently-updated first.
  Future<List<SessionMeta>> listSessions();

  /// The recorded working directory for [sessionId], or null when the
  /// session is unknown or records no cwd.
  Future<String?> cwdFor(String sessionId);
}

/// [JsonlSessionStore] satisfies the index structurally; declaring the
/// interface makes that a checked contract rather than an accident, and lets
/// startup code take [SessionIndex] depend on it directly. [cwdFor] is
/// implemented on the store itself (manifest-only read: no materialization).
extension JsonlSessionStoreIndex on JsonlSessionStore {}

/// Bridges any [SessionStore] into a [SessionIndex] without a new
/// construction path: `SessionIndexStore(store)` is a read-only view of an
/// instance the caller already owns.
class SessionIndexStore implements SessionIndex {
  SessionIndexStore(this._store);

  final SessionStore _store;

  @override
  Future<List<SessionMeta>> listSessions() => _store.listSessions();

  @override
  Future<String?> cwdFor(String sessionId) async {
    // Read the manifest directly where the store exposes it, so the index
    // never triggers the jsonl store's lazy materialization (a write);
    // fall back to loadSession for other backends.
    final store = _store;
    if (store is JsonlSessionStore) {
      return store.cwdFor(sessionId);
    }
    try {
      return (await store.loadSession(sessionId)).cwd;
    } on StateError {
      return null; // unknown session — the index reports absence, not error
    }
  }
}

/// The default startup index: the JSONL sessions at the default location.
///
/// SP3 replaces this constant default with a read of [RuntimeConfig]'s
/// session backend selection. Until then every pre-runtime caller — the
/// resume picker, `--resume`'s cwd restore, `--list` — resolves this.
SessionIndex resolveSessionIndex() =>
    JsonlSessionStore.defaultLocation() as SessionIndex;
