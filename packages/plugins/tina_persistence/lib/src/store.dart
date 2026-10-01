/// The persistence plugin's session store over `tina_sqlite`.
///
/// One SQLite file, one `openTinaDatabase` (versioned, pragmas, rollback
/// on throw). One append-only entry-log table (`log_registry`) holds every
/// session's rows in one rowid order. Each **entry** row's payload names
/// its session — `slice: <session id>` — so a session's slice is the
/// registry row (`type: tina.session`, naming the session id) plus every
/// row that names it, wherever those rows sit in the file. Parent and
/// child sessions share one store file and interleave freely: a parent's
/// turn keeps appending after a child registered, and attribution puts
/// each row where it belongs. (The first cut read a slice as a contiguous
/// rowid run — "up to the next registry row" — which misfiled the parent's
/// post-spawn rows into the child's slice.)
///
/// The rowid order is the truth — there is no second counter to disagree
/// with, and the schema exposes no update and no delete, so deletion is
/// impossible by construction. A slice's rows must be strictly increasing
/// in rowid and their payload `seq`s must read 0, 1, 2, … in slice order
/// (`seq` travels inside the payload, so the check needs no store-side
/// counter); a violated run is corruption.
///
/// The payload is one JSON object per row — the same bytes the loop's
/// listeners publish and the same bytes a JSON Lines twin would hold
/// (`swapJsonLinesWithSqlite` pins that property in tina_sqlite's own
/// tests). Every call goes through the poison-pill guard: the first
/// failure poisons the link and every later call reports the original
/// cause, so a broken store fails loudly instead of silently dropping
/// entries.
library;

import 'state_compatibility.dart';
import 'dart:convert';
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
    int? lastActivityKey,
    this.title,
    this.model,
    this.details,
    this.lastSavedAt,
    this.summary,
  }) : lastActivityKey = lastActivityKey ?? registryKey;

  /// The session id the host started it with.
  final String id;

  /// The registry row where the session's slice begins.
  final int registryKey;

  /// Most recent registry, metadata or entry row for this session. Row order
  /// reflects local activity, including appends to a resumed conversation.
  final int lastActivityKey;

  /// How many log rows follow the registry row (a lower bound while the
  /// session is still running in another process: this reader sees the
  /// rows committed when it read).
  final int entries;

  /// The title given at creation, when there was one.
  final String? title;
  final String? model;

  /// Timestamp of the latest committed registry, metadata or entry row.
  /// Derived from the existing SQLite log, so older stores need no migration.
  final DateTime? lastSavedAt;

  /// A short preview of the first user input, independent of generated output.
  final String? summary;

  /// The session's counters (depth, children in flight, tokens spent)
  /// as the registry row carries them, or null when the row predates
  /// details.
  final SessionDetails? details;

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

/// The link. Each persistence plugin owns its connection; [open] and
/// [close] bracket it. Parent and child connections can share a file.
final class SessionStore {
  SessionStore._(this.file, this._db, this._log);

  /// The store file's path.
  final String file;

  final Database _db;
  final TinaEntryLog _log;

  /// The registry row's payload type.
  static const _markerType = 'tina.session';

  /// The store file's schema version. Bump when the layout changes; the
  /// open step refuses anything newer than this code knows. Version 2:
  /// entry rows carry `slice`, so a session's slice is by attribution,
  /// not by contiguity — version 1 files (contiguous slices) are
  /// refused.
  static const _schemaVersion = 2;

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
    return SessionStore._(
        path, db, TinaEntryLog.attach(db, table: 'log_registry'));
  }

  Never _fail(String doing, Object e) =>
      throw SessionStoreException('session store $file failed while $doing', e);

  Map<String, Object?> _payloadOf(SessionEntry e) =>
      Map<String, Object?>.of(e.toJson());

  bool _isMarker(Map<String, Object?> payload) =>
      payload['type'] == _markerType;

  /// Record a new session: appends the registry row that begins the
  /// session's slice. Returns the row's id. [details] rides on the same
  /// row — it is session-level fact, not log content — and comes back
  /// with [readDetails].
  int createSession(String id,
      {String? title, String? model, SessionDetails? details}) {
    try {
      return _log.append({
        'type': _markerType,
        'session_id': id,
        if (title != null) 'title': title,
        if (model != null) 'model': model,
        if (details != null) 'details': details.toJson(),
        if (model != null) 'model': model,
      });
    } on Object catch (e) {
      _fail('recording session $id', e);
    }
  }

  /// Atomically add a converted snapshot. A repeat of the same source is a
  /// no-op, including after the imported session has accumulated newer turns.
  /// A different snapshot never overwrites or appends to an existing session.
  bool importSnapshot(
    String id, {
    required String fingerprint,
    required Map<String, Object?> provenance,
    required List<SessionEntry> entries,
    String? title,
  }) {
    final payloads = <String>[];
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].seq != i)
        throw const FormatException('import sequence gap');
      final entry = decodePersistedEntry(entries[i].toJson());
      payloads.add(jsonEncode({'slice': id, ...entry.toJson()}));
    }
    final marker = jsonEncode({
      'type': _markerType,
      'session_id': id,
      if (title != null) 'title': title,
      'details': SessionDetails().toJson(),
      'legacy_import': {'fingerprint': fingerprint, ...provenance},
    });
    return _log.guardWrite((db) {
      final prior = db.select(
          "SELECT payload FROM log_registry WHERE json_extract(payload, '\$.type') = ? "
          "AND json_extract(payload, '\$.session_id') = ? ORDER BY id LIMIT 1",
          [_markerType, id]);
      if (prior.isNotEmpty) {
        final metadata = jsonDecode(prior.single['payload'] as String) as Map;
        if ((metadata['legacy_import'] as Map?)?['fingerprint'] == fingerprint)
          return false;
        throw FormatException(
            'destination $id already exists with a different source; use another store');
      }
      final insert =
          db.prepare('INSERT INTO log_registry (at, payload) VALUES (?, ?)');
      try {
        final at = DateTime.now().toUtc().toIso8601String();
        for (final payload in [marker, ...payloads]) {
          insert.execute([at, payload]);
        }
      } finally {
        insert.close();
      }
      return true;
    });
  }

  /// One session's stored details — depth, children in flight, tokens
  /// spent — as the registry row carries them. Defaults (all zero) when
  /// the row predates details. Unknown for a session this store has
  /// never heard of: that throws like every other read of a missing
  /// session.
  SessionDetails readDetails(String sessionId) {
    try {
      SessionDetails? found;
      for (final row in _log.readAll()) {
        final p = row.payload;
        if (_isMarker(p) && p['session_id'] == sessionId) {
          final d = p['details'];
          found = d is Map<String, dynamic>
              ? SessionDetails.fromJson(Map<String, Object?>.of(d))
              : SessionDetails();
        }
      }
      // The last marker row naming the session wins: details updates
      // append fresh marker rows, and the newest reading is the truth.
      if (found != null) return found;
      throw SessionStoreException(
          'session store $file has no session named $sessionId');
    } on SessionStoreException {
      rethrow;
    } on Object catch (e) {
      _fail('reading details of session $sessionId', e);
    }
  }

  /// Persist [details] for [sessionId]: one fresh marker row naming the
  /// same session (the log is append-only; nothing is updated in
  /// place). [readDetails] and the hosts' resume take the newest row,
  /// so this is an update by convention — and the registry stays a
  /// history, not a mutable cell.
  void updateDetails(String sessionId, SessionDetails details,
      {String? model}) {
    try {
      _log.append({
        'type': _markerType,
        'session_id': sessionId,
        'details': details.toJson(),
        if (model != null) 'model': model,
      });
    } on Object catch (e) {
      _fail('updating details of session $sessionId', e);
    }
  }

  /// Append entries to a session's slice, in order, one row per entry.
  /// The entries' own `seq` is untouched: it is the loop's position, and
  /// the store is the cache, not a second truth. Each row names its
  /// session (`slice`), so interleaved writers — a parent's turn and a
  /// child's spawn running through one file — stay attributed when
  /// readers come back.
  void append(String sessionId, List<SessionEntry> entries) {
    try {
      for (final e in entries) {
        final payload = _payloadOf(e);
        _log.append({'slice': sessionId, ...payload});
      }
    } on Object catch (e) {
      _fail('appending to session $sessionId', e);
    }
  }

  /// One row per session, with latest metadata and entries counted by slice.
  /// Metadata updates and interleaved children do not create extra sessions.
  List<StoredSession> list() {
    try {
      final sessions = <String, StoredSession>{};
      final counts = <String, int>{};
      final latest = <String, int>{};
      final savedAt = <String, DateTime?>{};
      final summaries = <String, String>{};
      for (final row in _log.readAll()) {
        final payload = row.payload;
        if (_isMarker(payload)) {
          final id = payload['session_id'] as String;
          latest[id] = row.id;
          savedAt[id] = DateTime.tryParse(row.at);
          final previous = sessions[id];
          final details = payload['details'];
          sessions[id] = StoredSession(
            id: id,
            registryKey: previous?.registryKey ?? row.id,
            entries: 0,
            title: payload['title'] as String? ?? previous?.title,
            model: payload['model'] as String? ?? previous?.model,
            details: details is Map<String, dynamic>
                ? SessionDetails.fromJson(Map<String, Object?>.of(details))
                : previous?.details,
          );
        } else {
          final id = payload['slice'] as String;
          latest[id] = row.id;
          savedAt[id] = DateTime.tryParse(row.at);
          counts[id] = (counts[id] ?? 0) + 1;
          if (!summaries.containsKey(id)) {
            String? text;
            if (payload['type'] == InputRecordedEntry.kindName) {
              text = payload['text'] as String?;
            } else if (payload['type'] == MessageAppendedEntry.kindName) {
              final message = payload['message'];
              if (message is Map && message['role'] == 'user') {
                final decoded =
                    Message.fromJson(Map<String, dynamic>.from(message));
                if (!decoded.isSynthetic)
                  text = decoded.content
                      .whereType<TextBlock>()
                      .map((b) => b.text)
                      .join('\n');
              }
            }
            final summary = text?.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (summary != null && summary.isNotEmpty) {
              summaries[id] = String.fromCharCodes(summary.runes.take(160));
            }
          }
        }
      }
      return [
        for (final session in sessions.values)
          StoredSession(
            id: session.id,
            registryKey: session.registryKey,
            entries: counts[session.id] ?? 0,
            lastActivityKey: latest[session.id],
            title: session.title,
            model: session.model,
            details: session.details,
            lastSavedAt: savedAt[session.id],
            summary: summaries[session.id],
          )
      ];
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
  /// row itself plus every entry row that names the session. Rows sit
  /// wherever interleaved writers put them; attribution, not contiguity,
  /// assembles the slice. A resume or an auditor starts here.
  List<TinaLogEntry> readLog(String sessionId) {
    try {
      final start = _registryKey(sessionId);
      return [
        for (final row in _log.since(start - 1))
          if (row.id == start ||
              (!_isMarker(row.payload) && row.payload['slice'] == sessionId))
            row,
      ];
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
            decodePersistedEntry(Map<String, Object?>.of(row.payload)),
      ];
    } on SessionStoreException {
      rethrow;
    } on Object catch (e) {
      _fail('decoding session $sessionId', e);
    }
  }

  /// Every broken run inside one session's slice. Empty means intact; a
  /// gap is corruption — WAL truncation on a crash can legitimately lose
  /// only the tail, never a middle. Two properties are checked: the
  /// slice's rowids are strictly increasing (rows of interleaved
  /// sessions interleave, so consecutive is not required), and the
  /// payload `seq`s read 0, 1, 2, … in slice order — the position check
  /// the doc promises, catchable without a store-side counter.
  List<StoreGap> checkGaps(String sessionId) {
    // Entry rows only: the registry row carries no seq and is not part
    // of the run. (Re-registration and details-update markers name the
    // session but carry no `slice`, so readLog never mixes them in.)
    final rows =
        readLog(sessionId).where((r) => !_isMarker(r.payload)).toList();
    final out = <StoreGap>[];
    var lastSeq = -1;
    for (var i = 0; i < rows.length; i++) {
      final seq = (rows[i].payload['seq'] as num?)?.toInt() ?? 0;
      if (seq != lastSeq + 1 || (i > 0 && rows[i].id <= rows[i - 1].id)) {
        out.add(StoreGap(i == 0 ? 0 : rows[i - 1].id, rows[i].id));
      }
      lastSeq = seq;
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
