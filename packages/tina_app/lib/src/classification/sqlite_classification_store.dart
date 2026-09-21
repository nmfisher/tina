import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:classifier/classification.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'file_classification_store.dart';

/// SQLite owns the authoritative records, task references and directory tree.
/// All SQL and migration work runs on one worker isolate per open store.
class SqliteClassificationStore implements CheckpointStore {
  final String root;
  final ReceivePort _replies = ReceivePort();
  final _ready = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  static final _writers = <String>{};
  late final StreamSubscription<dynamic> _subscription;
  late SendPort _worker;
  late bool exists;
  int _next = 0;
  Future<void>? _closing;
  bool _writing = false;
  Object? _failure;

  SqliteClassificationStore._(this.root);

  static Future<SqliteClassificationStore> open(
    String projectRoot, {
    bool create = false,
    void Function(String)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    // Include initialization/migration in same-process writer exclusion. POSIX
    // advisory locks alone cannot distinguish worker isolates in one process.
    String? reservation;
    if (create ||
        await File(
          p.join(projectRoot, '.tina', 'classifications', 'manifest.json'),
        ).exists()) {
      reservation = p.join(
        await Directory(projectRoot).resolveSymbolicLinks(),
        '.tina',
        'classifications',
      );
      if (!_writers.add(reservation))
        throw StateError('Classification is already running');
    }
    final store = SqliteClassificationStore._(
      p.join(p.absolute(projectRoot), '.tina', 'classifications'),
    );
    var opening = true;
    var cancelled = false;
    SendPort? startup;
    cancelSignal?.then(
      (_) {
        if (opening) {
          cancelled = true;
          startup?.send('cancel');
        }
      },
      onError: (Object _) {
        if (opening) {
          cancelled = true;
          startup?.send('cancel');
        }
      },
    );
    store._subscription = store._replies.listen((message) {
      if (message is Map && message.containsKey('opening')) {
        startup = message['opening'] as SendPort;
        if (cancelled) startup!.send('cancel');
        return;
      }
      if (message is Map && message.containsKey('progress')) {
        try {
          onProgress?.call(message['progress'] as String);
        } catch (_) {}
        return;
      }
      if (message is Map) {
        store._worker = message['port'] as SendPort;
        store.exists = message['exists'] as bool;
        store._ready.complete();
      } else if (message is List &&
          message.length == 3 &&
          message.first is int) {
        final pending = store._pending.remove(message[0]);
        if (message[1] == true) {
          pending?.complete(message[2]);
        } else {
          pending?.completeError(StateError(message[2] as String));
        }
      } else {
        final error = StateError(
          'Classification database worker stopped: $message',
        );
        store._failure = error;
        if (!store._ready.isCompleted) store._ready.completeError(error);
        for (final pending in store._pending.values) {
          pending.completeError(error);
        }
        store._pending.clear();
      }
    });
    try {
      await Isolate.spawn(
        _serve,
        (
          projectRoot: projectRoot,
          create: create,
          reply: store._replies.sendPort,
        ),
        onError: store._replies.sendPort,
        onExit: store._replies.sendPort,
      );
      await store._ready.future;
      opening = false;
      return store;
    } catch (_) {
      opening = false;
      await store._subscription.cancel();
      store._replies.close();
      rethrow;
    } finally {
      if (reservation != null) _writers.remove(reservation);
    }
  }

  Future<Object?> _call(String method, [Object? args]) {
    if (_failure != null) return Future.error(_failure!);
    if (_closing != null && method != 'close')
      throw StateError('Classification store is closed');
    final id = _next++;
    final result = Completer<Object?>();
    _pending[id] = result;
    _worker.send([id, method, args]);
    return result.future;
  }

  Future<void> close() => _closing ??= () async {
    try {
      if (_failure == null) await _call('close');
    } finally {
      await _subscription.cancel();
      _replies.close();
    }
  }();

  @override
  Future<T> withWriter<T>(Future<T> Function() work) async {
    final canonical = p.join(
      await Directory(p.dirname(p.dirname(root))).resolveSymbolicLinks(),
      '.tina',
      'classifications',
    );
    if (!_writers.add(canonical))
      throw StateError('Classification is already running');
    try {
      await _call('lock');
      _writing = true;
      try {
        return await work();
      } finally {
        _writing = false;
        await _call('unlock');
      }
    } finally {
      _writers.remove(canonical);
    }
  }

  void _checkWriter() {
    if (!_writing) throw StateError('Classification writes require withWriter');
  }

  @override
  Future<Map<String, dynamic>?> readManifest() async =>
      (await _call('manifest')) as Map<String, dynamic>?;
  @override
  Future<Map<String, dynamic>?> readRecord(String id) async =>
      (await _call('record', id)) as Map<String, dynamic>?;
  @override
  Future<void> writeRecord(String id, Map<String, Object?> record) async {
    _checkWriter();
    await _call('write', [id, record]);
  }

  @override
  Future<void> writeManifest(Map<String, Object?> manifest) async {
    _checkWriter();
    await _call('replace', manifest);
  }

  @override
  Future<void> publish(
    String key,
    String id,
    Map<String, Object?> record,
  ) async {
    _checkWriter();
    await _call('publish', [key, id, record]);
  }

  @override
  Future<void> retainTasks(Set<String> keys) async {
    _checkWriter();
    await _call('retain', keys.toList());
  }

  /// Small summaries only: neither provenance nor evidence is loaded here.
  Future<Map<String, dynamic>?> node(String path) async =>
      (await _call('node', path)) as Map<String, dynamic>?;
  Future<List<Map<String, dynamic>>> children(
    String path, {
    int offset = 0,
    int limit = 100,
  }) async {
    if (offset < 0 || limit < 1 || limit > 1000)
      throw ArgumentError('Invalid index page');
    return (await _call('children', [path, offset, limit]) as List)
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> details(String path) async =>
      (await _call('details', path)) as Map<String, dynamic>;
}

Future<void> _serve(
  ({String projectRoot, bool create, SendPort reply}) args,
) async {
  final port = ReceivePort();
  var cancelled = false;
  final calls = StreamController<List>();
  final subscription = port.listen((message) {
    if (message == 'cancel') {
      cancelled = true;
    } else {
      calls.add(message as List);
    }
  });
  args.reply.send({'opening': port.sendPort});
  _Database? store;
  try {
    store = await _Database.open(
      args.projectRoot,
      args.create,
      (text) => args.reply.send({'progress': text}),
      () => cancelled,
    );
    if (cancelled) throw StateError('Classification database open cancelled');
    args.reply.send({'port': port.sendPort, 'exists': store.db != null});
    await for (final call in calls.stream) {
      final id = call[0] as int;
      final method = call[1] as String;
      try {
        final result = await store.call(method, call[2]);
        args.reply.send([id, true, result]);
      } catch (e) {
        args.reply.send([id, false, '$e']);
      }
      if (method == 'close') break;
    }
  } finally {
    await store?.close();
    await subscription.cancel();
    unawaited(calls.close());
    port.close();
  }
}

class _Database {
  final String root;
  final bool writable;
  Database? db;
  RandomAccessFile? lock;
  _Database(this.root, this.writable);

  Future<void> safe(String path) async {
    var current = p.dirname(root);
    for (final component in [
      null,
      ...p.split(p.relative(path, from: current)),
    ]) {
      if (component != null) current = p.join(current, component);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Classification storage cannot contain symlinks');
      }
    }
  }

  static Future<_Database> open(
    String projectRoot,
    bool create,
    void Function(String) progress,
    bool Function() cancelled,
  ) async {
    final store = _Database(
      p.join(p.absolute(projectRoot), '.tina', 'classifications'),
      create,
    );
    final path = p.join(store.root, 'index.db');
    void check() {
      if (cancelled())
        throw StateError('Classification database open cancelled');
    }

    try {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        await store.safe('$path$suffix');
      }
      final legacy = File(p.join(store.root, 'manifest.json'));
      await store.safe(legacy.path);
      final migrate = await legacy.exists();
      check();
      final present = await File(path).exists();
      if (!create && !migrate && !present) return store;
      if (!present || migrate) {
        await Directory(store.root).create(recursive: true);
        await store.acquire();
        try {
          check();
          store.db = sqlite3.open(path);
          store.db!.execute('PRAGMA foreign_keys=ON');
          store.db!.execute('PRAGMA busy_timeout=5000');
          store.db!.execute('PRAGMA journal_mode=WAL');
          store.schema();
          if (migrate) {
            progress('Migrating saved classifications to SQLite (one time)…');
            await store.migrate(projectRoot, check);
          }
          final ignore = File(p.join(store.root, '.gitignore'));
          await store.safe(ignore.path);
          await ignore.writeAsString('*\n');
        } finally {
          await store.release();
        }
        if (!create) {
          store.db!.close();
          store.db = sqlite3.open(path, mode: OpenMode.readOnly);
        }
      } else {
        // Opening another connection must not acquire/release the run's OS
        // lock: POSIX locks belong to the process, not the isolate.
        store.db = sqlite3.open(
          path,
          mode: create ? OpenMode.readWrite : OpenMode.readOnly,
        );
        store.db!.execute('PRAGMA busy_timeout=5000');
        if (create && store.db!.userVersion == 0) {
          // A process may have stopped after creating the file but before the
          // schema transaction committed. Such an empty database is retryable.
          await store.acquire();
          try {
            store.db!.execute('PRAGMA journal_mode=WAL');
            store.schema();
            final ignore = File(p.join(store.root, '.gitignore'));
            await store.safe(ignore.path);
            await ignore.writeAsString('*\n');
          } finally {
            await store.release();
          }
        }
      }
      if (store.db!.userVersion != 1)
        throw StateError('Unsupported classification database version');
      store.db!.execute('PRAGMA foreign_keys=ON');
      // Readers retain one coherent snapshot while the indexing connection
      // publishes newer checkpoints. WAL keeps these reads off the writer lock.
      if (!create) store.db!.execute('BEGIN');
      return store;
    } catch (_) {
      await store.close();
      rethrow;
    }
  }

  void schema() {
    if (db!.userVersion == 1) return;
    if (db!.userVersion != 0)
      throw StateError('Unsupported classification database version');
    transaction(() {
      db!.execute('''
        CREATE TABLE records (
          id TEXT PRIMARY KEY, coverage TEXT, outcome TEXT, form TEXT NOT NULL,
          explanation TEXT, evidence TEXT, value TEXT, header TEXT NOT NULL
        );
        CREATE TABLE labels (
          record TEXT NOT NULL REFERENCES records(id), position INTEGER NOT NULL,
          value TEXT NOT NULL, evidence TEXT NOT NULL, PRIMARY KEY(record, position)
        );
        CREATE TABLE nodes (path TEXT PRIMARY KEY, parent TEXT);
        CREATE INDEX node_parent ON nodes(parent, path);
        CREATE TABLE refs (
          key TEXT PRIMARY KEY, record TEXT NOT NULL REFERENCES records(id),
          node TEXT, kind TEXT, stage TEXT
        );
        CREATE INDEX node_refs ON refs(node, kind, stage);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      ''');
      db!.userVersion = 1;
    });
  }

  T transaction<T>(T Function() work) {
    db!.execute('BEGIN IMMEDIATE');
    try {
      final result = work();
      db!.execute('COMMIT');
      return result;
    } catch (_) {
      db!.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> acquire() async {
    if (lock != null) throw StateError('Classification is already running');
    final path = p.join(root, '.lock');
    await safe(path);
    final file = await File(path).open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
      lock = file;
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  Future<void> release() async {
    final file = lock;
    lock = null;
    if (file != null) {
      try {
        await file.unlock();
      } finally {
        await file.close();
      }
    }
  }

  Future<void> close() async {
    await release();
    db?.close();
    db = null;
  }

  void insert(String id, Map<String, dynamic> record) {
    if (canonicalFingerprint(record) != id)
      throw const FormatException('Invalid classification record hash');
    if (db!.select('SELECT 1 FROM records WHERE id=?', [id]).isNotEmpty) return;
    final header = Map<String, dynamic>.from(record);
    final result = header['result'];
    final structured =
        result is Map &&
        result.length == 4 &&
        const [
          'outcome',
          'value',
          'evidence',
          'explanation',
        ].every(result.containsKey);
    final value = structured ? result['value'] : null;
    final labels =
        value is Map &&
            value.length == 1 &&
            value['labels'] is List &&
            (value['labels'] as List).every(
              (v) =>
                  v is Map &&
                  v.length == 2 &&
                  v['value'] is String &&
                  v['evidence'] is List,
            )
        ? value['labels'] as List
        : null;
    final coverage = header['coverage'];
    if (coverage != null) header.remove('coverage');
    if (structured) header.remove('result');
    db!.execute('INSERT INTO records VALUES (?,?,?,?,?,?,?,?)', [
      id,
      coverage == null ? null : jsonEncode(coverage),
      structured ? result['outcome'] : null,
      !structured
          ? 'raw'
          : labels == null
          ? 'value'
          : 'labels',
      structured ? result['explanation'] : null,
      structured ? jsonEncode(result['evidence']) : null,
      structured && labels == null ? jsonEncode(value) : null,
      jsonEncode(header),
    ]);
    if (labels != null) {
      final statement = db!.prepare('INSERT INTO labels VALUES (?,?,?,?)');
      try {
        for (var i = 0; i < labels.length; i++) {
          statement.execute([
            id,
            i,
            labels[i]['value'],
            jsonEncode(labels[i]['evidence']),
          ]);
        }
      } finally {
        statement.close();
      }
    }
  }

  Map<String, dynamic>? record(String id) {
    final rows = db?.select('SELECT * FROM records WHERE id=?', [id]);
    if (rows == null || rows.isEmpty) return null;
    final row = rows.single;
    final result = Map<String, dynamic>.from(
      jsonDecode(row['header'] as String) as Map,
    );
    if (row['coverage'] != null)
      result['coverage'] = jsonDecode(row['coverage'] as String);
    if (row['form'] != 'raw')
      result['result'] = {
        'outcome': row['outcome'],
        'value': row['form'] == 'labels'
            ? {
                'labels': [
                  for (final label in db!.select(
                    'SELECT value,evidence FROM labels WHERE record=? ORDER BY position',
                    [id],
                  ))
                    {
                      'value': label['value'],
                      'evidence': jsonDecode(label['evidence'] as String),
                    },
                ],
              }
            : jsonDecode(row['value'] as String),
        'evidence': jsonDecode(row['evidence'] as String),
        'explanation': row['explanation'],
      };
    return result;
  }

  void reference(String key, String id) {
    String? node, kind, stage;
    if (key.startsWith('task:')) {
      final parts = key.substring(5).split('::');
      if (parts.length == 2 || parts.length == 3 && parts[2] == 'local') {
        final path = parts.first;
        if (path == '.' ||
            !path.startsWith('/') &&
                !path
                    .split('/')
                    .any((v) => v.isEmpty || v == '.' || v == '..')) {
          node = path;
          kind = parts[1];
          stage = parts.length == 3 ? 'local' : 'merged';
          var current = path;
          while (true) {
            final parent = current == '.'
                ? null
                : current.contains('/')
                ? current.substring(0, current.lastIndexOf('/'))
                : '.';
            db!.execute('INSERT OR IGNORE INTO nodes VALUES (?,?)', [
              current,
              parent,
            ]);
            if (parent == null) break;
            current = parent;
          }
        }
      }
    }
    db!.execute(
      'INSERT INTO refs VALUES (?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET record=excluded.record,node=excluded.node,kind=excluded.kind,stage=excluded.stage',
      [key, id, node, kind, stage],
    );
  }

  void replace(Map<String, dynamic> manifest) {
    db!.execute('DELETE FROM refs');
    db!.execute('DELETE FROM nodes');
    for (final entry in (manifest['records'] as Map).entries) {
      reference(entry.key as String, entry.value as String);
    }
  }

  Future<void> migrate(String projectRoot, void Function() check) async {
    final old = FileClassificationStore(projectRoot);
    final imported = db!
        .select("SELECT 1 FROM meta WHERE key='legacy_imported'")
        .isNotEmpty;
    if (!imported) {
      final manifest = await old.readManifest();
      check();
      if (manifest == null ||
          manifest['schema_version'] != classificationSchemaVersion) {
        throw StateError(
          'Cannot migrate an unreadable or unsupported classification manifest',
        );
      }
      final directory = Directory(p.join(root, 'records'));
      await safe(directory.path);
      db!.execute('BEGIN IMMEDIATE');
      try {
        if (await directory.exists()) {
          await for (final file in directory.list(followLinks: false)) {
            check();
            final name = p.basename(file.path);
            if (!RegExp(r'^[a-f0-9]{64}\.json$').hasMatch(name)) continue;
            final id = name.substring(0, 64);
            final value = await old.readRecord(id);
            check();
            if (value == null)
              throw StateError('Cannot migrate classification record $id');
            insert(id, value);
          }
        }
        for (final id in (manifest['records'] as Map).values) {
          if (db!.select('SELECT 1 FROM records WHERE id=?', [id]).isEmpty) {
            throw StateError(
              'Missing classification record $id during migration',
            );
          }
        }
        replace(manifest);
        check();
        db!.execute("INSERT INTO meta VALUES ('legacy_imported','1')");
        db!.execute('COMMIT');
      } catch (_) {
        db!.execute('ROLLBACK');
        rethrow;
      }
    }
    // Only remove files already committed to SQLite. A crash in cleanup is
    // harmless: the marker makes the next open resume cleanup, never reimport.
    final directory = Directory(p.join(root, 'records'));
    if (await directory.exists()) {
      await for (final file in directory.list(followLinks: false)) {
        check();
        final name = p.basename(file.path);
        if (file is File &&
            RegExp(r'^[a-f0-9]{64}\.json$').hasMatch(name) &&
            db!.select('SELECT 1 FROM records WHERE id=?', [
              name.substring(0, 64),
            ]).isNotEmpty) {
          await file.delete();
        }
      }
      if (await directory.list().isEmpty) await directory.delete();
    }
    await File(p.join(root, 'manifest.json')).delete();
  }

  Map<String, dynamic> summary(String path, bool hasChildren) {
    final rows = db!.select(
      '''SELECT f.kind,f.stage,f.record,r.coverage,r.outcome,
      (SELECT json_group_array(value) FROM
        (SELECT value FROM labels WHERE record=r.id ORDER BY position)) AS labels
      FROM refs f JOIN records r ON r.id=f.record WHERE f.node=?''',
      [path],
    );
    return {
      'path': path,
      'has_children': hasChildren,
      'results': [for (final row in rows) Map<String, dynamic>.from(row)],
    };
  }

  Future<Object?> call(String method, dynamic args) async {
    switch (method) {
      case 'close':
        await close();
        return null;
      case 'lock':
        if (!writable || db == null)
          throw StateError('Classification database is read-only');
        await acquire();
        return null;
      case 'unlock':
        await release();
        return null;
      case 'manifest':
        if (db == null) return null;
        return {
          'schema_version': classificationSchemaVersion,
          'records': {
            for (final row in db!.select('SELECT key,record FROM refs'))
              row['key'] as String: row['record'],
          },
        };
      case 'record':
        return record(args as String);
      case 'node':
        if (db == null) return null;
        final nodes = db!.select(
          'SELECT path,EXISTS(SELECT 1 FROM nodes c WHERE c.parent=n.path) AS children FROM nodes n WHERE path=?',
          [args],
        );
        return nodes.isEmpty
            ? null
            : summary(args as String, nodes.first['children'] == 1);
      case 'children':
        if (db == null) return <Map<String, dynamic>>[];
        final nodes = db!.select(
          'SELECT path,EXISTS(SELECT 1 FROM nodes c WHERE c.parent=n.path) AS children FROM nodes n WHERE parent=? ORDER BY path LIMIT ? OFFSET ?',
          [args[0], args[2], args[1]],
        );
        return [
          for (final row in nodes)
            summary(row['path'] as String, row['children'] == 1),
        ];
      case 'details':
        if (db == null) return <String, dynamic>{};
        return {
          for (final row in db!.select(
            'SELECT key,record FROM refs WHERE node=?',
            [args],
          ))
            row['key'] as String: record(row['record'] as String),
        };
      case 'write':
      case 'replace':
      case 'publish':
      case 'retain':
        if (lock == null || !writable)
          throw StateError('Classification writes require a writer lock');
        transaction(() {
          if (method == 'write')
            insert(
              args[0] as String,
              Map<String, dynamic>.from(args[1] as Map),
            );
          if (method == 'replace')
            replace(Map<String, dynamic>.from(args as Map));
          if (method == 'publish') {
            insert(
              args[1] as String,
              Map<String, dynamic>.from(args[2] as Map),
            );
            reference(args[0] as String, args[1] as String);
          }
          if (method == 'retain') {
            final keep = (args as List).cast<String>().toSet();
            for (final row in db!.select(
              "SELECT key FROM refs WHERE key LIKE 'task:%'",
            )) {
              final key = row['key'] as String;
              if (!keep.contains(key.substring(5)))
                db!.execute('DELETE FROM refs WHERE key=?', [key]);
            }
            db!.execute('''WITH RECURSIVE live(path) AS (
              SELECT DISTINCT node FROM refs WHERE node IS NOT NULL
              UNION SELECT n.parent FROM nodes n JOIN live l ON n.path=l.path WHERE n.parent IS NOT NULL
            ) DELETE FROM nodes WHERE path NOT IN (SELECT path FROM live)''');
          }
        });
        return null;
      default:
        throw ArgumentError('Unknown classification operation $method');
    }
  }
}
