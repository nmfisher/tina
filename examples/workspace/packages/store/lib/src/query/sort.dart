/// Sort keys and comparators for query results.
library;

/// Build a comparator from an ordered list of [keys] (later keys break
/// ties). Each key maps a value to a [Comparable]; [descending] inverts.
Comparator<T> comparatorBy<T>(
  List<Comparable Function(T)> keys, {
  Set<int> descending = const {},
}) {
  return (a, b) {
    for (var i = 0; i < keys.length; i++) {
      final result = keys[i](a).compareTo(keys[i](b));
      if (result != 0) {
        final flip = descending.contains(i) ? -1 : 1;
        return result * flip;
      }
    }
    return 0;
  };
}
