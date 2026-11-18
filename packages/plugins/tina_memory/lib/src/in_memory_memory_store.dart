import '../memory_store_api.dart';

/// A pure-Dart [MemoryStoreApi] twin: one store per process, same
/// semantics as the sqlite implementation. Deterministic tests and,
/// eventually, the wasm engine through the opener seam.
final class InMemoryMemoryStore implements MemoryStoreApi {
  InMemoryMemoryStore({this.scope = MemoryScope.project});

  @override
  final MemoryScope scope;

  final _entries = <MemoryEntry>[];
  var _nextId = 1;
  bool _closed = false;

  @override
  String get file => ':memory:';

  void _open() {
    if (_closed) throw StateError('store is closed');
  }

  @override
  MemoryEntry remember(String text,
      {required MemoryCategory category, required String updatedBy}) {
    _open();
    if (text.trim().isEmpty) throw const FormatException('text is empty');
    final now = DateTime.now().toUtc();
    final entry = MemoryEntry(
      id: _nextId++,
      scope: scope,
      category: category,
      text: text,
      createdAt: now,
      updatedAt: now,
      updatedBy: updatedBy,
    );
    _entries.add(entry);
    return entry;
  }

  @override
  MemoryEntry revise(int id, String text,
      {required DateTime expected,
      required String updatedBy,
      MemoryCategory? category}) {
    _open();
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) throw FormatException('no memory entry #$id');
    final current = _entries[index];
    if (current.updatedAt != expected) {
      throw MemoryRevisionConflict(current);
    }
    final revised = MemoryEntry(
      id: current.id,
      scope: current.scope,
      category: category ?? current.category,
      text: text,
      createdAt: current.createdAt,
      updatedAt: DateTime.now().toUtc(),
      updatedBy: updatedBy,
      lastRecalled: current.lastRecalled,
      recallCount: current.recallCount,
    );
    _entries[index] = revised;
    return revised;
  }

  @override
  MemoryEntry? forget(int id) {
    _open();
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return null;
    return _entries.removeAt(index);
  }

  @override
  MemoryEntry? entry(int id) {
    _open();
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  @override
  List<MemoryEntry> recall(String query, {int limit = 20}) {
    _open();
    final terms = _terms(query);
    if (terms.isEmpty) return const [];
    final now = DateTime.now().toUtc();
    final matched = _entries
        .where((e) => terms.every((t) => e.text.toLowerCase().contains(t)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final bumped = matched.take(limit).map((e) => MemoryEntry(
          id: e.id,
          scope: e.scope,
          category: e.category,
          text: e.text,
          createdAt: e.createdAt,
          updatedAt: e.updatedAt,
          updatedBy: e.updatedBy,
          lastRecalled: now,
          recallCount: e.recallCount + 1,
        ));
    final byId = {for (final e in bumped) e.id: e};
    _entries.mapInPlace((e) => byId[e.id] ?? e);
    return byId.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  List<MemoryEntry> hottest({int limit = 100}) {
    _open();
    final sorted = [..._entries]..sort((a, b) {
        final byCount = b.recallCount.compareTo(a.recallCount);
        if (byCount != 0) return byCount;
        return (b.lastRecalled ?? b.updatedAt)
            .compareTo(a.lastRecalled ?? a.updatedAt);
      });
    return sorted.take(limit).toList();
  }

  @override
  List<MemoryEntry> list({MemoryCategory? category}) {
    _open();
    return [
      for (final e in _entries)
        if (category == null || e.category == category) e
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Map<String, Object?> stats() {
    _open();
    final byCategory = <String, int>{};
    var recalls = 0;
    for (final e in _entries) {
      byCategory[e.category.name] = (byCategory[e.category.name] ?? 0) + 1;
      recalls += e.recallCount;
    }
    return {
      'scope': scope.name,
      'file': file,
      'entries': _entries.length,
      'byCategory': byCategory,
      'recalls': recalls,
    };
  }

  @override
  void close() => _closed = true;

  static List<String> _terms(String query) => [
        for (final match in RegExp(r'[A-Za-z0-9_./-]+').allMatches(query))
          match.group(0)!.toLowerCase()
      ].toSet().toList();
}

extension<T> on List<T> {
  void mapInPlace(T Function(T) f) {
    for (var i = 0; i < length; i++) {
      this[i] = f(this[i]);
    }
  }
}
