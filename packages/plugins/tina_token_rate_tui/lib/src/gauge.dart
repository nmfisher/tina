/// A sliding-window estimator for the rate at which tokens are produced.
///
/// Pure data: callers feed `(time, cumulativeTokens)` samples via [sample]
/// and read the resulting tokens-per-second with [rate]. Samples older than
/// [window] are pruned so the rate reflects recent throughput rather than a
/// session-long average.
final class TokenRateWindow {
  TokenRateWindow({this.window = const Duration(milliseconds: 2500)});

  /// The window over which the rate is computed.
  final Duration window;

  final List<(DateTime, double)> _samples = [];

  /// Keep at least [minSampleGap] between redundant samples: a repeated
  /// cumulative count within the gap adds no information and would bloat the
  /// list on a hot ticker.
  static const _minSampleGap = Duration(milliseconds: 500);

  /// Record a sample at [now] with the cumulative token count. A new sample
  /// is only appended when the count moved or enough time elapsed.
  void sample(DateTime now, double cumulativeTokens) {
    if (_samples.isNotEmpty &&
        _samples.last.$2 == cumulativeTokens &&
        now.difference(_samples.last.$1) < _minSampleGap) {
      return;
    }
    _samples.add((now, cumulativeTokens));
    final cutoff = now.subtract(window);
    while (_samples.length > 2 && _samples.first.$1.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  /// Tokens per second across the retained samples, or 0 when there are fewer
  /// than two samples (no measurable window).
  double rate(DateTime now) {
    if (_samples.length < 2) return 0;
    final first = _samples.first;
    final last = _samples.last;
    final elapsed = last.$1.difference(first.$1).inMilliseconds;
    if (elapsed <= 0) return 0;
    return (last.$2 - first.$2) * 1000 / elapsed;
  }

  /// Drop all samples (e.g. when a turn ends).
  void clear() => _samples.clear();

  int get sampleCount => _samples.length;
}
