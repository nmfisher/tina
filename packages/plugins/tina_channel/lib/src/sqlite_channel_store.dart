/// The native channel store over `tina_sqlite`: one SQLite file, one
/// versioned `openTinaDatabase` (pragmas set there: WAL so readers
/// never block writers, busy timeout so concurrent processes wait
/// instead of erroring, synchronous FULL so an acknowledged write is
/// durable). Feature schema owned here, per the tina_sqlite contract.
///
/// Tables: `channels`, append-only `messages`, `members` for presence,
/// and `channel_deliveries` for recipient checkpoints.
/// `#lobby` is ensured at every open, so the first agent into a fresh
/// workspace finds it there.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:tina_sqlite/tina_sqlite.dart';

import '../channel_store_api.dart';

export '../channel_store_api.dart';

/// The link. Each channel plugin, CLI invocation and TUI pane owns its
/// own connection; WAL lets them share one file.
final class SqliteChannelStore implements ChannelStoreApi {
  SqliteChannelStore._(this.file, this._db);

  final String file;
  final Database _db;

  /// The store file's schema version. Bump when the layout changes;
  /// the open step refuses anything newer than this code knows.
  static const schemaVersion = 3;

  /// The channel every workspace starts with.
  static const lobbyChannel = '#lobby';

  /// Open (or create) the store at [path]. Older schemas are migrated
  /// in place inside the open transaction. Future schemas are rejected.
  static SqliteChannelStore open(String path) {
    final Database db;
    try {
      db = openTinaDatabase(
        path,
        schemaVersion: schemaVersion,
        migrate: _migrate,
        migrations: const {1: _migrateV1ToV2, 2: _createDeliveries},
      );
    } on Object catch (e) {
      throw ChannelStoreException('cannot open channel store $path', e);
    }
    final store = SqliteChannelStore._(path, db);
    try {
      store.ensureChannel(lobbyChannel);
      return store;
    } on Object catch (e) {
      db.close();
      throw ChannelStoreException('cannot create $lobbyChannel in $path', e);
    }
  }

  /// The 1→2 step (the compaction release): every channel gains its
  /// compaction point, defaulting to 0 — no compaction, exactly v1's
  /// behavior. `ALTER TABLE` keeps every existing row untouched.
  static void _migrateV1ToV2(Database db) {
    db.execute('ALTER TABLE channels '
        'ADD COLUMN compaction_id INTEGER NOT NULL DEFAULT 0');
  }

  static void _createDeliveries(Database db) {
    db.execute('CREATE TABLE channel_deliveries ('
        'session_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, '
        'checkpoint TEXT NOT NULL)');
  }

  static void _migrate(Database db) {
    db.execute('CREATE TABLE channels ('
        'name TEXT PRIMARY KEY, '
        'created_at TEXT NOT NULL, '
        'compaction_id INTEGER NOT NULL DEFAULT 0)');
    db.execute('CREATE TABLE messages ('
        'id INTEGER PRIMARY KEY, '
        'channel TEXT NOT NULL REFERENCES channels(name), '
        'sender TEXT NOT NULL, '
        'text TEXT NOT NULL, '
        'type TEXT NOT NULL, '
        'mentions TEXT, '
        'reply_to INTEGER REFERENCES messages(id), '
        'created_at TEXT NOT NULL)');
    db.execute(
        'CREATE INDEX messages_channel_id ON messages(channel, id)');
    db.execute('CREATE TABLE members ('
        'channel TEXT NOT NULL REFERENCES channels(name), '
        'name TEXT NOT NULL, '
        'role TEXT NOT NULL, '
        'status TEXT NOT NULL, '
        'summary TEXT, '
        'last_seen TEXT NOT NULL, '
        'PRIMARY KEY (channel, name))');
    _createDeliveries(db);
  }

  static ChannelMessage _rowToMessage(dynamic row) => ChannelMessage(
        id: row['id'] as int,
        channel: row['channel'] as String,
        sender: row['sender'] as String,
        text: row['text'] as String,
        type: ChannelMessageType.parse(row['type'] as String),
        createdAt: DateTime.parse(row['created_at'] as String),
        mentions: _decodeMentions(row['mentions'] as String?),
        replyTo: row['reply_to'] as int?,
      );

  List<ChannelMessage> _selectMessages(String sql, List<Object?> params) =>
      [for (final row in _db.select(sql, params)) _rowToMessage(row)];

  Never _fail(String doing, Object e) =>
      throw ChannelStoreException('channel store $file failed while $doing', e);

  static String _now() => DateTime.now().toUtc().toIso8601String();

  @override
  void ensureChannel(String name) {
    final normalized = normalizeChannelName(name);
    try {
      _db.execute(
          'INSERT OR IGNORE INTO channels (name, created_at) VALUES (?, ?)',
          [normalized, _now()]);
    } on Object catch (e) {
      _fail('creating channel $normalized', e);
    }
  }

  @override
  List<ChannelSummary> listChannels() {
    try {
      final rows = _db.select(
          'SELECT c.name AS name, '
          '(SELECT COUNT(*) FROM messages m '
          ' WHERE m.channel = c.name AND m.id > c.compaction_id) AS messages, '
          '(SELECT COUNT(*) FROM members k WHERE k.channel = c.name) AS members, '
          '(SELECT COALESCE(MAX(m.id), 0) FROM messages m '
          ' WHERE m.channel = c.name AND m.id > c.compaction_id) AS last_id, '
          '(SELECT MAX(m.created_at) FROM messages m '
          ' WHERE m.channel = c.name AND m.id > c.compaction_id) AS last_at '
          'FROM channels c ORDER BY c.name');
      return [
        for (final row in rows)
          ChannelSummary(
            name: row['name'] as String,
            messages: row['messages'] as int,
            members: row['members'] as int,
            lastMessageId: row['last_id'] as int,
            lastMessageAt: DateTime.tryParse(row['last_at'] as String? ?? ''),
          )
      ];
    } on Object catch (e) {
      _fail('listing channels', e);
    }
  }

  @override
  ChannelMessage post(String channel,
      {required String sender,
      required String text,
      ChannelMessageType type = ChannelMessageType.message,
      List<String>? mentions,
      int? replyTo}) {
    final normalized = normalizeChannelName(channel);
    if (sender.trim().isEmpty) {
      throw const FormatException('sender is empty');
    }
    final storedMentions = (mentions == null || mentions.isEmpty)
        ? null
        : jsonEncode(mentions);
    try {
      return _guardedPost(
          normalized, sender, text, type, storedMentions, replyTo);
    } on ChannelStoreException {
      rethrow;
    } on Object catch (e) {
      _fail('posting to $normalized', e);
    }
  }

  ChannelMessage _guardedPost(String channel, String sender, String text,
      ChannelMessageType type, String? storedMentions, int? replyTo) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(
          'INSERT OR IGNORE INTO channels (name, created_at) VALUES (?, ?)',
          [channel, _now()]);
      final statement = _db.prepare(
          'INSERT INTO messages '
          '(channel, sender, text, type, mentions, reply_to, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)');
      try {
        final at = _now();
        statement.execute(
            [channel, sender, text, type.name, storedMentions, replyTo, at]);
        final id = _db.lastInsertRowId;
        _db.execute('COMMIT');
        return ChannelMessage(
          id: id,
          channel: channel,
          sender: sender,
          text: text,
          type: type,
          mentions: _decodeMentions(storedMentions),
          replyTo: replyTo,
          createdAt: DateTime.parse(at),
        );
      } finally {
        statement.close();
      }
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  List<ChannelMessage> read(String channel,
      {int? sinceId, DateTime? sinceTime, int limit = 50, bool fromOldest = false}) {
    if (limit < 1) throw const FormatException('limit must be at least 1');
    final normalized = normalizeChannelName(channel);
    final sinceAt = sinceTime?.toUtc().toIso8601String();
    try {
      // The view starts at the compaction point: superseded rows stay
      // in the table (the audit trail) but no read returns them.
      final point = compactionPoint(normalized);
      final effectiveSince =
          sinceId == null ? point : sinceId > point ? sinceId : point;
      var where = 'WHERE channel = ?';
      final params = <Object?>[normalized];
      if (effectiveSince > 0) {
        where += ' AND id > ?';
        params.add(effectiveSince);
      }
      if (sinceAt != null) {
        where += ' AND created_at > ?';
        params.add(sinceAt);
      }
      final rows = _db.select(
          'SELECT id, channel, sender, text, type, mentions, reply_to, '
          'created_at FROM messages $where '
          'ORDER BY id ${fromOldest ? 'ASC' : 'DESC'} LIMIT ?',
          [...params, limit]);
      final messages = [for (final row in rows) _rowToMessage(row)];
      return fromOldest ? messages : messages.reversed.toList();
    } on Object catch (e) {
      _fail('reading $normalized', e);
    }
  }

  @override
  ChannelDeliveryState? deliveryState(String sessionId) {
    try {
      final rows = _db.select(
          'SELECT revision, checkpoint FROM channel_deliveries WHERE session_id = ?',
          [sessionId]);
      if (rows.isEmpty) return null;
      final row = rows.single;
      final checkpoint = jsonDecode(row['checkpoint'] as String) as Map;
      return ChannelDeliveryState(
        agent: checkpoint['agent'] as String,
        revision: row['revision'] as int,
        cursors: Map<String, int>.from(checkpoint['cursors'] as Map),
        pending: List<String>.from(checkpoint['pending'] as List),
        recent: List<String>.from(checkpoint['recent'] as List),
      );
    } on Object catch (error) {
      _fail('reading channel delivery checkpoint', error);
    }
  }

  @override
  bool saveDeliveryState(String sessionId, ChannelDeliveryState state,
      {required int? expectedRevision}) {
    final checkpoint = jsonEncode({
      'agent': state.agent,
      'cursors': state.cursors,
      'pending': state.pending,
      'recent': state.recent,
    });
    try {
      if (expectedRevision == null) {
        _db.execute('INSERT OR IGNORE INTO channel_deliveries '
            '(session_id, revision, checkpoint) VALUES (?, ?, ?)',
            [sessionId, state.revision, checkpoint]);
      } else {
        _db.execute('UPDATE channel_deliveries SET revision = ?, checkpoint = ? '
            'WHERE session_id = ? AND revision = ?',
            [state.revision, checkpoint, sessionId, expectedRevision]);
      }
      return _db.updatedRows == 1;
    } on Object catch (error) {
      _fail('saving channel delivery checkpoint', error);
    }
  }

  static List<String> _decodeMentions(String? stored) {
    if (stored == null || stored.isEmpty) return const [];
    final decoded = jsonDecode(stored) as List;
    return [for (final name in decoded) name as String];
  }

  @override
  ChannelMessage? message(String channel, int id) {
    final normalized = normalizeChannelName(channel);
    try {
      final rows = _db.select(
          'SELECT id, channel, sender, text, type, mentions, reply_to, '
          'created_at FROM messages WHERE channel = ? AND id = ?',
          [normalized, id]);
      if (rows.isEmpty) return null;
      final row = rows.single;
      return ChannelMessage(
        id: row['id'] as int,
        channel: row['channel'] as String,
        sender: row['sender'] as String,
        text: row['text'] as String,
        type: ChannelMessageType.parse(row['type'] as String),
        createdAt: DateTime.parse(row['created_at'] as String),
        mentions: _decodeMentions(row['mentions'] as String?),
        replyTo: row['reply_to'] as int?,
      );
    } on Object catch (e) {
      _fail('reading message $id of $normalized', e);
    }
  }

  @override
  void setMember(String channel, String member,
      {required String status,
      String? role,
      String? summary,
      bool announce = true}) {
    final normalized = normalizeChannelName(channel);
    if (member.trim().isEmpty) {
      throw const FormatException('member is empty');
    }
    try {
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute(
            'INSERT OR IGNORE INTO channels (name, created_at) VALUES (?, ?)',
            [normalized, _now()]);
        _db.execute(
            'INSERT INTO members (channel, name, role, status, summary, '
            'last_seen) VALUES (?, ?, ?, ?, ?, ?) '
            'ON CONFLICT(channel, name) DO UPDATE SET '
            'role = excluded.role, status = excluded.status, '
            'summary = excluded.summary, last_seen = excluded.last_seen',
            [
              normalized,
              member,
              role ?? 'agent',
              status,
              summary,
              _now(),
            ]);
        if (announce) {
          // The sender column carries the name; the text stays
          // name-less so rendered lines read `* nick working — …`.
          final text = summary == null || summary.isEmpty
              ? status
              : '$status — $summary';
          _db.execute(
              'INSERT INTO messages '
              '(channel, sender, text, type, mentions, reply_to, created_at) '
              'VALUES (?, ?, ?, ?, NULL, NULL, ?)',
              [normalized, member, text, ChannelMessageType.status.name, _now()]);
        }
        _db.execute('COMMIT');
      } on Object {
        _db.execute('ROLLBACK');
        rethrow;
      }
    } on Object catch (e) {
      _fail('setting presence of $member in $normalized', e);
    }
  }

  @override
  List<ChannelMember> members(String channel) {
    final normalized = normalizeChannelName(channel);
    try {
      final rows = _db.select(
          'SELECT channel, name, role, status, summary, last_seen '
          'FROM members WHERE channel = ? ORDER BY name',
          [normalized]);
      return [
        for (final row in rows)
          ChannelMember(
            channel: row['channel'] as String,
            name: row['name'] as String,
            role: row['role'] as String,
            status: row['status'] as String,
            summary: row['summary'] as String?,
            lastSeen: DateTime.parse(row['last_seen'] as String),
          )
      ];
    } on Object catch (e) {
      _fail('listing members of $normalized', e);
    }
  }

  @override
  int lastMessageId(String channel) {
    final normalized = normalizeChannelName(channel);
    try {
      final row = _db.select(
          'SELECT COALESCE(MAX(id), 0) AS m FROM messages WHERE channel = ?',
          [normalized]).first;
      return row['m'] as int;
    } on Object catch (e) {
      _fail('reading last message id of $normalized', e);
    }
  }

  @override
  int compactionPoint(String channel) {
    final normalized = normalizeChannelName(channel);
    try {
      final rows = _db.select(
          'SELECT compaction_id FROM channels WHERE name = ?', [normalized]);
      if (rows.isEmpty) return 0;
      return rows.single['compaction_id'] as int;
    } on Object catch (e) {
      _fail('reading compaction point of $normalized', e);
    }
  }

  @override
  ChannelCompaction compact(String channel,
      {required String actor,
      int keep = compactDefaultKeep,
      bool clear = false}) {
    if (keep < 0) throw const FormatException('keep must not be negative');
    final normalized = normalizeChannelName(channel);
    try {
      _db.execute('BEGIN IMMEDIATE');
      try {
        final prior = compactionPoint(normalized);
        final newest = lastMessageId(normalized);
        // The retained tail: the most recent `keep` rows of the current
        // view. A clear retains nothing. An already-compacted room
        // never resurrects superseded rows (the prior point floors the
        // scan).
        final tail = clear
            ? const <int>[]
            : _db
                .select(
                    'SELECT id FROM messages WHERE channel = ? '
                    'AND id > ? ORDER BY id DESC LIMIT ?',
                    [normalized, prior, keep])
                .map((row) => row['id'] as int)
                .toList();
        // The view is ids STRICTLY past the point, so the point sits
        // one below the oldest retained row (or at the newest row for
        // a clear, hiding everything).
        final point = tail.isEmpty ? newest : tail.last - 1;
        // What THIS compaction hides: everything from the prior point
        // up to the new one (for a clear, that is the whole view).
        final digested = _db.select(
            'SELECT COUNT(*) AS n FROM messages WHERE channel = ? '
            'AND id > ? AND id <= ?',
            [normalized, prior, point]).single['n'] as int;
        final superseded = _selectMessages(
            'SELECT id, channel, sender, text, type, mentions, reply_to, '
            'created_at FROM messages WHERE channel = ? '
            'AND id > ? AND id <= ? ORDER BY id ASC',
            [normalized, prior, point]);
        _db.execute('UPDATE channels SET compaction_id = ? WHERE name = ?',
            [point, normalized]);
        _db.execute('COMMIT');
        var digestId = 0;
        if (!clear) {
          // Posted after the point transaction: post() runs its own
          // guarded write, and the digest belongs AFTER everything the
          // point kept — it lands at the newest id and heads the view.
          final digest = post(
            normalized,
            sender: actor,
            text: 'Compacted $normalized: superseded $digested '
                'message${digested == 1 ? '' : 's'}'
                '${digested == 0 ? '' : ' (ids ${prior + 1}\u{2013}$point)'}; '
                '${tail.length} recent message${tail.length == 1 ? '' : 's'} '
                'retained. Full history stays in the database.',
            type: ChannelMessageType.system,
          );
          digestId = digest.id;
        }
        return ChannelCompaction(
          channel: normalized,
          point: point,
          digested: digested,
          digestId: digestId,
          superseded: superseded,
        );
      } on Object {
        _db.execute('ROLLBACK');
        rethrow;
      }
    } on ChannelStoreException {
      rethrow;
    } on Object catch (e) {
      _fail('compacting $normalized', e);
    }
  }

  @override
  void close() {
    try {
      _db.close();
    } on Object catch (e) {
      _fail('closing', e);
    }
  }
}
