/// Persisted limits have no terminal, filesystem or provider dependency.
final class RequestLimits {
  const RequestLimits(
      {this.globalTokens = 0,
      this.sessionTokens = 0,
      this.turnTokens = 0,
      this.requestTokens = 0,
      this.childTokens = 0,
      this.childDepth = 3,
      this.childConcurrency = 3,
      this.requestsPerMinute = 0,
      this.minIntervalMs = 0,
      this.maxConcurrent = 4});
  final int globalTokens, sessionTokens, turnTokens, requestTokens, childTokens;
  final int childDepth,
      childConcurrency,
      requestsPerMinute,
      minIntervalMs,
      maxConcurrent;

  factory RequestLimits.fromMap(Map<String, dynamic> values) {
    int read(String key, [int fallback = 0]) {
      final value = values[key];
      if (value == null) return fallback;
      if (value is! int || value < 0)
        throw FormatException('limits.$key must be a nonnegative integer');
      return value;
    }

    return RequestLimits(
        globalTokens: read('max_global_tokens'),
        sessionTokens: read('max_session_tokens'),
        turnTokens: read('max_turn_tokens'),
        requestTokens: read('max_request_tokens'),
        childTokens: read('max_sub_agent_tokens'),
        childDepth: read('max_sub_agent_depth', 3),
        childConcurrency: read('max_sub_agent_concurrency', 3),
        requestsPerMinute: read('requests_per_minute'),
        minIntervalMs: read('min_request_interval_ms'),
        maxConcurrent: read('max_concurrent_requests', 4));
  }
}
