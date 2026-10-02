# tina_sqlite

The one SQLite seam for tina: a versioned **open-or-create** step, a generic
append-only **entry log**, and a generic **key-value table**, each wrapped in
the same poison-pill guard.

Feature stores share a `schema()` that no-ops on the current `user_version`, throws
on anything newer, and creates + stamps in one transaction; `PRAGMA
foreign_keys=ON` / `busy_timeout` / `journal_mode=WAL` at open; and the
finding that a store whose database dies mid-session must never come back
half-alive.

## What's here

### `openTinaDatabase`

Opens (or creates) a database file and runs the versioned schema work:

- `PRAGMA foreign_keys=ON`, `busy_timeout`, `journal_mode=WAL` at open;
- `user_version == current` → return, nothing to do;
- `user_version > current` → **throw** `UnsupportedDatabaseVersion` (a
  future tina must not silently write into a schema it doesn't know);
- `user_version == 0` on a fresh file → run the migration in **one
  transaction**, set `user_version`, return;
- anything else → unsupported.

Callbacks receive the raw `sqlite3.Database`, so callers build exactly the
tables they need. The open step itself is schema-free.

### `TinaEntryLog`

An append-only log keyed by an integer rowid the database picks. One table
(`entries`), inserts only — the schema exposes no update or delete, and no
method of the class does either. Rows come back oldest-first; iteration
with `since(rowid)` resumes where a previous pass stopped. `log(schema,
name)` attaches further logs to the same connection without a second
migration.

### `TinaKv`

A namespaced key-value table (`kv`): `get`, `set`, `delete`, `keys`.
Values are arbitrary JSON-encodable Dart values stored as TEXT via
`jsonEncode`; keys are TEXT. The schema covers every caller — per-feature
tables stay the caller's business, built through the open callback.

### `TinaJsonLinesFile`

A small JSON Lines file — one JSON object per line, appended under an
exclusive lock, read back oldest-first. The entry log's plain-file twin:
`append` writes, `readAll` parses, and a truncated tail line (a crash
mid-append) surfaces as a `FormatException`, never as silently dropped
rows.

### `swapJsonLinesWithSqlite`

The property this package exists to demonstrate: a reader on the JSON
Lines file and a reader on the SQLite log observe **the same entries, in
the same order** — the durable log and the file agree line-for-line, so
backing either with the other changes no observable behavior. The helper
appends a batch to both and asserts nothing; it returns both readers and
leaves the equality property to the caller's test (see
`test/jsonlines_swap_test.dart`).

## Poison-pill guard

Every store here follows one rule, taken from the classification store's
worker-isolate design: once the underlying database or file fails, the
wrapper is **closed and stays closed**. `TinaEntryLog` and `TinaKv` turn a
`SqliteException` into `TinaSqliteClosedException` and mark themselves
dead; every later call rethrows the pill instead of returning a value from
a broken store. There is no reopen path — reopen by building a new store.

## Example

```dart
final db = openTinaDatabase(
  p.join(dir.path, 'state.db'),
  migrate: (db) => db.execute('CREATE TABLE custom (x TEXT);'),
);
final log = TinaEntryLog.attach(db, 'events');
await log.append({'kind': 'turn', 'id': 1});
final entries = await log.readAll(); // [{kind: turn, id: 1}]

final kv = TinaKv.attach(db, 'session');
await kv.set('active', {'id': 's-1'});
await kv.get('active'); // {id: s-1}
```
