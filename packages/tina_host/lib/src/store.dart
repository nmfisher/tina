/// The session store: the host's persistence link over `tina_sqlite`.
///
/// One SQLite file, one `openTinaDatabase` (versioned, pragmas, rollback
/// on throw). One append-only entry-log table (`log_registry`) holds every
/// session's entries in one rowid order; a session's slice begins at a
/// registry row (`type: tina.session`, naming the session id) and runs to
/// the next registry row. The rowid order is the truth — there is no
/// second counter to disagree with, and the schema exposes no update and
/// no delete, so deletion is impossible by construction.
///
/// The payload is one JSON object per row — the same bytes the loop's
/// listeners publish and the same bytes a JSON Lines twin would hold
/// (`swapJsonLinesWithSqlite` pins that property in tina_sqlite's own
/// tests). `seq` travels inside the payload, so `seq == position in
/// slice` is checkable off-storage; a violated run is corruption.
///
/// Every call goes through the poison-pill guard: the first failure
/// poisons the link and every later call reports the original cause, so
/// a broken store fails loudly instead of silently dropping entries.
library;

import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:tina_core/tina_core.dart';
import 'package:tina_sqlite/tina_sqlite.dart';

/// The store link failed — at open, at write, or mid-read. The host does
/// not swallow this: a store that cannot persist must stop the session
/// loudly, because a session that lies about durability is worse than
/// none.
final class SessionStoreException implements Exception {
  const SessionStoreException(this.message, [this.cause]);

  final String message;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      'SessionStoreException: $message${cause == null ? '' : ' ($cause)'}';
}

/// One session the store knows about.
final class StoredSession {
  const StoredSession({
    required this.id,
    required this.registryKey,
    required this.entries,
    this.title,
  });

  /// The session id the host started it with.
  final String id;

  /// The registry row where the session's slice begins.
  final int registryKey;

  /// How many log rows follow the registry row (a lower bound while the
  /// session is still running in another process: this reader sees the
  /// rows committed when it read).
  final int entries;

  /// The title given at creation, when there was one.
  final String? title;

  @override
  String toString() => 'StoredSession($id, $entries entries'
      '${title == null ? '' : ', $title'})';
}

/// A run of rowids that is not consecutive inside one session's slice.
final class StoreGap {
  const StoreGap(this.afterId, this.beforeId);

  /// The rowid before the hole.
  final int afterId;

  /// The rowid after the hole.
  final int beforeId;

  @override
  String toString() => 'gap: no rows between $afterId and $beforeId';
}

/// The link. The host owns at most one per store file; [open] and
/// [close] bracket it.
final class SessionStore {
  SessionStore._(this.file, this._db, this._log);

  /// The store file's path.
  final String file;

  final Database _db;
  final TinaEntryLog _log;

  /// The registry row's payload type.
  static const _markerType = 'tina.session';

  /// The store file's schema version. Bump when the layout changes; the
  /// open step refuses anything newer than this code knows.
  static const _schemaVersion = 1;

  /// Open (or create) the store at [path]. Never silently degrades: a
  /// file from a newer schema throws before anything is written.
  static SessionStore open(String path) {
    final Database db;
    try {
      db = openTinaDatabase(
        path,
        schemaVersion: _schemaVersion,
        migrate: (d) => createEntryLogTable(d, table: 'log_registry'),
      );
    } on Object catch (e) {
      throw SessionStoreException('cannot open session store $path', e);
    }
    return SessionStore._(path, db, TinaEntryLog.attach(db, table: 'log_registry'));
  }

  Never _fail(String doing, Object e) =>
      throw SessionStoreException('session store $file failed while $doing', e);

  Map<String, Object?> _payloadOf(SessionEntry e) =>
      Map<String, Object?>.of(e.toJson());

  bool _isMarker(Map<String, Object?> payload) =>
      payload['type'] == _markerType;

  /// Record a new session: appends the registry row that begins the
  /// session's slice. Returns the row's id.
  int createSession(String id, {String? title}) {
    try {
      return _log.append({
        'type': _markerType,
        'session_id': id,
        if (title != null) 'title': title,
      });
    } on Object catch (e) {
      _fail('recording session $id', e);
    }
  }

  /// Append entries to a session's slice, in order, one row per entry.
  /// The entries' own `seq` is untouched: it is the loop's position, and
  /// the store is the cache, not a second truth.
  void append(String sessionId, List<SessionEntry> entries) {
    try {
      for (final e in entries) {
        _log.append(_payloadOf(e));
      }
    } on Object catch (e) {
      _fail('appending to session $sessionId', e);
    }
  }

  /// The store's sessions, oldest first. Cheap: registry rows only —
  /// never a `SELECT *` over every session's history.
  List<StoredSession> list() {
    try {
      final out = <StoredSession>[];
      int? key;
      String? id;
      String? title;
      var count = 0;
      void flush() {
        if (id == null) return;
        out.add(StoredSession(
            id: id!, registryKey: key!, entries: count, title: title));
        id = null;
        title = null;
        count = 0;
      }

      for (final row in _log.readAll()) {
        final p = row.payload;
        if (_isMarker(p)) {
          flush();
          key = row.id;
          id = p['session_id'] as String?;
          title = p['title'] as String?;
        } else {
          count++;
        }
      }
      flush();
      return out;
    } on Object catch (e) {
      _fail('listing sessions', e);
    }
  }

  /// The id of the registry row that begins [sessionId]'s slice.
  int _registryKey(String sessionId) {
    for (final row in _log.readAll()) {
      final p = row.payload;
      if (_isMarker(p) && p['session_id'] == sessionId) return row.id;
    }
    throw SessionStoreException('session store $file has no session '
        'named $sessionId');
  }

  /// The raw rows of one session's slice, oldest first — the registry
  /// row itself plus every entry row up to the next session's registry
  /// row. A resume or an auditor starts here.
  List<TinaLogEntry> readLog(String sessionId) {
    try {
      final start = _registryKey(sessionId);
      final rows = _log.since(start - 1);
      final out = <TinaLogEntry>[];
      for (final row in rows) {
        if (row.id != start && _isMarker(row.payload)) break;
        out.add(row);
      }
      return out;
    } on Object catch (e) {
      _fail('reading session $sessionId', e);
    }
  }

  /// One session's entries, decoded, oldest first. An unreadable payload
  /// throws — a log this code cannot read is never silently skimmed.
  List<SessionEntry> readEntries(String sessionId) {
    try {
      return [
        for (final row in readLog(sessionId))
          if (!_isMarker(row.payload))
            SessionEntry.fromJson(Map<String, Object?>.of(row.payload)),
      ];
    } on SessionStoreException {
      rethrow;
    } on Object catch (e) {
      _fail('decoding session $sessionId', e);
    }
  }

  /// Every non-consecutive run inside one session's slice. Empty means
  /// intact; the gaps are corruption — WAL truncation on a crash can
  /// legitimately lose only the tail, never a middle.
  List<StoreGap> checkGaps(String sessionId) {
    final rows = readLog(sessionId);
    final out = <StoreGap>[];
    for (var i = 1; i < rows.length; i++) {
      if (rows[i].id != rows[i - 1].id + 1) {
        out.add(StoreGap(rows[i - 1].id, rows[i].id));
      }
    }
    return out;
  }

  /// Close the link. Every later call throws through the poison pill.
  void close() {
    try {
      _db.close();
    } on Object catch (e) {
      _fail('closing', e);
    }
  }
}
