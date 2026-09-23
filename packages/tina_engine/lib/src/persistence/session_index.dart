import 'dart:io';

import 'session_store.dart';
import 'jsonl_session_store.dart';
import 'session_store_plugin.dart';

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

/// The startup index for the selected `[sessions] provider` (SP3): the
/// JSONL sessions at the default location (or [root] when given, e.g. from
/// config).
///
/// Selection and the composition's plugin list must agree, so both resolve
/// through [sessionStorePluginFor]'s id validation: an unknown provider
/// throws [FormatException] here — at startup, before any session read —
/// rather than resolving a different backend than the runtime will mount.
///
/// Until SP5 only `jsonl` exists; SP3's config read selects within that
/// set. [provider] defaults to 'jsonl'.
SessionIndex resolveSessionIndex({String provider = 'jsonl', Directory? root}) {
  // Validation-only: the id check is the point. The jsonl index reads the
  // same root the plugin would build a store at, so startup and the
  // runtime see one backend.
  sessionStorePluginFor(provider, root: root);
  return JsonlSessionStore(root ?? JsonlSessionStore.defaultSessionRoot());
}
