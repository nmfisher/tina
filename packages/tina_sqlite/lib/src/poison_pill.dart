/// The poison-pill guard, extracted from the classification store's
/// worker-isolate rule: once the underlying database fails, the wrapper
/// is **closed and stays closed**. A store that died mid-session never
/// comes back half-alive; every later call rethrows instead of returning
/// a value from a broken store. Reopen by building a new store — there
/// is no in-place recovery path.
library;

import 'package:sqlite3/sqlite3.dart';

/// Thrown by every call on a store whose database already failed once.
final class TinaSqliteClosedException implements Exception {
  const TinaSqliteClosedException(this.store, this.cause);

  /// Which store died (e.g. `'TinaEntryLog(events)'`).
  final String store;

  /// The original error that killed it.
  final Object cause;

  @override
  String toString() =>
      'TinaSqliteClosedException: $store is closed permanently '
      '(first failure: $cause)';
}

/// Mixin for wrappers over one [Database]. [guard] runs a read; [guardWrite]
/// runs a write inside `BEGIN IMMEDIATE`. On a [SqliteException] the store
/// disposes its handle, marks itself dead, and rethrows the pill — every
/// call after that rethrows the pill too. The pill is thrown, not returned:
/// callers write `store.get(...)` with no error channel to check.
mixin PoisonPillStore {
  /// The live database handle, or null once the store has died. Closing
  /// the handle is the die path's business ([_die] in the mixin's guard);
  /// callers close the shared connection themselves.
  Database? get db;

  /// A label for error messages.
  String get storeLabel;

  bool _dead = false;
  Object? _cause;

  /// Whether the store has taken the pill. Informational: callers do not
  /// need to check it — the next call throws either way.
  bool get isBroken => _dead;

  /// Run [work] under the guard.
  T guard<T>(T Function(Database db) work) {
    if (_dead) throw TinaSqliteClosedException(storeLabel, _cause!);
    final d = db;
    if (d == null) {
      _dead = true;
      _cause = StateError('database handle already disposed');
      throw TinaSqliteClosedException(storeLabel, _cause!);
    }
    try {
      return work(d);
    } on SqliteException catch (e) {
      _die(e);
      throw TinaSqliteClosedException(storeLabel, e);
    } on StateError catch (e) {
      // The handle was closed under the store (disposed, or killed by the
      // sqlite3 package's own failure path). Same verdict: the store is
      // dead; the pill keeps the original error as its cause.
      _die(e);
      throw TinaSqliteClosedException(storeLabel, e);
    }
  }

  /// Run [work] as one immediate transaction under the guard. A failure
  /// rolls back before the store dies, so the file is left consistent.
  T guardWrite<T>(T Function(Database db) work) => guard((d) {
        d.execute('BEGIN IMMEDIATE');
        try {
          final r = work(d);
          d.execute('COMMIT');
          return r;
        } on Object {
          d.execute('ROLLBACK');
          rethrow;
        }
      });

  void _die(Object cause) {
    _dead = true;
    _cause = cause;
    try {
      db?.close();
    } on Object {
      // Closing a broken handle is best effort; the pill is already set.
    }
  }
}
