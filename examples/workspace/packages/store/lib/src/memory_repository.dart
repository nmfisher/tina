/// An in-memory [Repository] — the reference implementation.
library;

import 'package:core/core.dart';

/// Keeps entities in a plain map. Thread-safety is caller's problem.
final class MemoryRepository<T extends Entity> implements Repository<T> {
  final Map<String, T> _entities = {};

  @override
  Future<Result<T, String>> fetch(String id) async {
    final entity = _entities[id];
    if (entity == null) return const Err(StoreErrors.notFound);
    return Ok(entity);
  }

  @override
  Future<Result<void, String>> save(T entity) async {
    _entities[entity.id] = entity;
    return const Ok(null);
  }

  @override
  Future<Result<List<T>, String>> list() async {
    final sorted = _entities.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return Ok(sorted);
  }

  @override
  Future<Result<void, String>> delete(String id) async {
    if (_entities.remove(id) == null) return const Err(StoreErrors.notFound);
    return const Ok(null);
  }

  /// Test hook: number of held entities.
  int get count => _entities.length;
}
