import 'package:sqlite3/sqlite3.dart';
import 'package:tina_sqlite/tina_sqlite.dart';

import 'store.dart';

/// A separate read-only connection. No migrations, journal-mode changes,
/// CREATE TABLE, or access to arbitrary SQL from model input.
final class HistoryReader {
  HistoryReader(String file)
      : db = sqlite3.open(file, mode: OpenMode.readOnly) {
    try {
      if (db.userVersion != SessionStore.schemaVersion) {
        throw UnsupportedDatabaseVersion(
            file, db.userVersion, SessionStore.schemaVersion);
      }
      db.execute('PRAGMA query_only=ON');
      db.execute('PRAGMA busy_timeout=1000');
    } on Object {
      db.close();
      rethrow;
    }
  }

  final Database db;
  void close() => db.close();

  // Only actual user/assistant text enters the history tools. In particular,
  // raw inputs, tool arguments/results, images, plugin state and synthetic
  // context messages are not searchable or returned as conversation text.
  static const _messages = '''
messages AS (
  SELECT id, at, json_extract(payload, '\$.slice') AS session_id,
    coalesce(json_extract(payload, '\$.seq'), 0) AS seq,
    json_extract(payload, '\$.message.role') AS role,
    (SELECT group_concat(json_extract(block.value, '\$.text'), char(10))
     FROM json_each(payload, '\$.message.content') AS block
     WHERE json_extract(block.value, '\$.type') = 'text') AS text
  FROM log_registry
  WHERE json_extract(payload, '\$.type') = 'message_appended'
    AND json_extract(payload, '\$.message.role') IN ('user', 'assistant')
    AND coalesce(json_extract(payload, '\$.message.synthetic'), 0) = 0
)
''';

  List<Map<String, Object?>> search(
      {required String query,
      required String? excludeSession,
      required int limit,
      bool orderByTime = false}) {
    final rows = db.select('''
WITH $_messages,
markers AS (
  SELECT json_extract(payload, '\$.session_id') AS session_id,
    max(CASE WHEN json_extract(payload, '\$.title') IS NOT NULL THEN id END)
      AS title_key
  FROM log_registry WHERE json_extract(payload, '\$.type') = 'tina.session'
  GROUP BY session_id
),
activity AS (
  SELECT coalesce(json_extract(payload, '\$.slice'),
                  json_extract(payload, '\$.session_id')) AS session_id,
    max(id) AS last_key
  FROM log_registry GROUP BY session_id
),
matching AS MATERIALIZED (
  SELECT id, session_id,
    substr(text, max(1, instr(lower(text), lower(?)) - 100), 400) AS snippet
  FROM messages WHERE text IS NOT NULL
    AND (? = '' OR instr(lower(text), lower(?)) > 0)
),
last_matches AS (
  SELECT session_id, max(id) AS match_key FROM matching GROUP BY session_id
)
SELECT a.session_id, a.last_key, l.at AS last_saved_at,
  substr(json_extract(t.payload, '\$.title'), 1, 200) AS title,
  coalesce(mt.snippet, substr(json_extract(t.payload, '\$.title'), 1, 400)) AS snippet
FROM activity a JOIN markers m ON m.session_id = a.session_id
JOIN log_registry l ON l.id = a.last_key
LEFT JOIN log_registry t ON t.id = m.title_key
LEFT JOIN last_matches lm ON lm.session_id = a.session_id
LEFT JOIN matching mt ON mt.id = lm.match_key
WHERE (? IS NULL OR a.session_id != ?)
  AND (? = '' OR instr(lower(json_extract(t.payload, '\$.title')), lower(?)) > 0
       OR lm.match_key IS NOT NULL)
ORDER BY ${orderByTime ? 'julianday(l.at) DESC,' : ''} a.last_key DESC LIMIT ?
''', [
      query,
      query,
      query,
      excludeSession,
      excludeSession,
      query,
      query,
      limit,
    ]);
    return [for (final row in rows) Map<String, Object?>.from(row)];
  }

  /// Defaults to the most recent messages, returned in conversation order.
  /// before_seq pages backwards without depending on new appended messages.
  Map<String, Object?> read(String sessionId,
      {required int? beforeSeq,
      required int limit,
      int? messageSeq,
      int textOffset = 0}) {
    final exists = db.select('''
SELECT 1 FROM log_registry
WHERE json_extract(payload, '\$.type') = 'tina.session'
  AND json_extract(payload, '\$.session_id') = ? LIMIT 1
''', [sessionId]);
    if (exists.isEmpty) throw const FormatException('Unknown session_id');
    final rows = db.select('''
WITH $_messages
SELECT seq, role, at, substr(text, ? + 1, 6000) AS text,
  length(text) > ? + 6000 AS text_truncated
FROM messages WHERE session_id = ? AND text IS NOT NULL
  AND (? IS NULL OR seq < ?)
  AND (? IS NULL OR seq = ?)
ORDER BY id DESC LIMIT ?
''', [
      textOffset,
      textOffset,
      sessionId,
      beforeSeq,
      beforeSeq,
      messageSeq,
      messageSeq,
      messageSeq == null ? limit + 1 : 1
    ]);
    if (messageSeq != null && rows.isEmpty)
      throw const FormatException('Unknown message_seq');
    final selected = rows.take(limit).toList().reversed.toList();
    return {
      'messages': [
        for (final row in selected)
          {
            ...row,
            'text_truncated': row['text_truncated'] == 1,
            'text_offset': textOffset,
            'next_text_offset':
                row['text_truncated'] == 1 ? textOffset + 6000 : null,
          }
      ],
      'next_before_seq': rows.length > limit ? selected.first['seq'] : null,
    };
  }
}
