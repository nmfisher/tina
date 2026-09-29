class InputTooLargeException implements Exception {
  const InputTooLargeException();
  @override
  String toString() =>
      'Input does not fit the configured context or chunk limits';
}

/// Packs contiguous scalar ranges against the complete request's budget.
/// Callers supply request construction and their boundary/overlap policy.
/// [fits] must be monotonic as a range grows.
Iterable<T> packInputRanges<T>({
  required int length,
  required int maxChunks,
  required T Function(int start, int end) build,
  required bool Function(T request) fits,
  required int Function(int start, int end) chooseEnd,
  int Function(int start, int end)? nextStart,
}) sync* {
  if (maxChunks <= 0) throw ArgumentError.value(maxChunks, 'maxChunks');
  var start = 0;
  var count = 0;
  do {
    if (count++ >= maxChunks || !fits(build(start, start))) {
      throw const InputTooLargeException();
    }
    var low = start;
    var high = length;
    while (low < high) {
      final end = (low + high + 1) ~/ 2;
      if (fits(build(start, end))) {
        low = end;
      } else {
        high = end - 1;
      }
    }
    if (low == start && start < length) {
      throw const InputTooLargeException();
    }
    final end = low == length ? low : chooseEnd(start, low);
    if (end < start || end > low || (end == start && start < length)) {
      throw StateError('Invalid packing boundary');
    }
    final packed = build(start, end);
    if (!fits(packed)) {
      throw const InputTooLargeException();
    }
    yield packed;
    if (end == length) break;
    final next = nextStart?.call(start, end) ?? end;
    if (next <= start || next > end) {
      throw StateError('Packing must advance without skipping evidence');
    }
    start = next;
  } while (start < length);
}
