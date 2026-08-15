/// The persistence interface every store implements.
library;

import 'result.dart';

/// A persisted entity with a stable identity.
abstract interface class Entity {
  String get id;
}

/// Minimal repository contract: fetch, save, list, delete.
///
/// Implementations return [Result] rather than throwing, so callers are
/// forced to handle the failure path at the type level.
abstract interface class Repository<T extends Entity> {
  /// Fetches the entity with [id], or `Err(NotFound)` if absent.
  Future<Result<T, String>> fetch(String id);

  /// Perserves [entity], inserting or updating as appropriate.
  Future<Result<void, String>> save(T entity);

  /// Lists all entities, ordered by id.
  Future<Result<List<T>, String>> list();

  /// Deletes the entity with [id]; `Err(NotFound)` if absent.
  Future<Result<void, String>> delete(String id);
}

/// The canonical error codes repositories may return.
abstract final class StoreErrors {
  static const notFound = 'not_found';
  static const ioFailure = 'io_failure';
  static const corrupt = 'corrupt';
}
