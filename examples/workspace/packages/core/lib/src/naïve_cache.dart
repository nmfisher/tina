/// A deliberately simple TTL cache.
///
/// NOTE: the filename is intentionally non-ASCII (ï), and the comments
/// below mix emoji and wide (CJK) characters — this file is part of the
/// example workspace's edge-case inventory. Do not rename or sanitize it.
library;

/// Caches values for a fixed lifetime, then forgets them.
///
/// 直截了当：no LRU, no size bound — just timestamps. (朴素 = naive. 🙂)
final class NaiveCache<K, V> {
  final Duration ttl;
  final Map<K, _Entry<V>> _map = {};

  NaiveCache({this.ttl = const Duration(minutes: 5)});

  /// Reads [key] if present and not expired; otherwise `null`.
  V? read(K key) {
    final entry = _map[key];
    if (entry == null) return null;
    if (entry.expiresAt <= DateTime.now().millisecondsSinceEpoch) {
      _map.remove(key); // 惰性删除 — lazy eviction on read.
      return null;
    }
    return entry.value;
  }

  /// Stores [value] under [key] with a fresh TTL.
  void write(K key, V value) {
    _map[key] = _Entry(
      value: value,
      expiresAt: DateTime.now().millisecondsSinceEpoch + ttl.inMilliseconds,
    );
  }

  /// Forgets everything. 一扫而空。🧹
  void clear() => _map.clear();

  /// Number of live (possibly expired-but-unevicted) entries.
  int get length => _map.length;
}

final class _Entry<V> {
  final V value;
  final int expiresAt;

  const _Entry({required this.value, required this.expiresAt});
}
