import 'dart:io';

/// Opt-in wire log for LLM requests: set `TINA_HTTP_LOG=/path/to/file` and
/// every request appends one JSON line — endpoint, model id, and the full
/// request body (never the Authorization header). Zero-cost when unset.
///
/// Answers "what model name was actually sent?" without a proxy: a 403 like
/// Hetzner's `{"error":"model use not permitted"}` is almost always a model
/// id the provider doesn't offer.
abstract final class HttpLog {
  static final String? _path = Platform.environment['TINA_HTTP_LOG'];
  static bool get enabled => _path != null;

  static void log(Uri endpoint, String body) {
    final p = _path;
    if (p == null) return;
    try {
      File(p).writeAsStringSync(
        '${DateTime.now().toIso8601String()} $endpoint $body\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // Best-effort logging — never break a request over it.
    }
  }
}
