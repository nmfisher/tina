/// The HTTP client over `dart:io`'s [HttpClient], moved verbatim from
/// `tina_llm` in wasm stage 2: one instance per provider, base URL set at
/// construction, [close] tears the underlying client down.
library;

import 'dart:io';

import 'package:tina_core/tina_core.dart';

/// The real client over `dart:io`'s [HttpClient]. One instance per
/// provider; [close] tears the underlying client down.
final class IoHttpEndpoint implements HttpClientPort {
  IoHttpEndpoint({required this.endpoint});

  /// The absolute base every [path] hangs off, e.g.
  /// `https://api.z.ai/api/anthropic` — the gateway prefix IS the
  /// endpoint, and `/v1/messages` must land on
  /// `.../api/anthropic/v1/messages`, not on the origin root. Read from
  /// the environment at runtime by the provider constructor — never
  /// baked into source.
  final String endpoint;

  HttpClient? _io;

  HttpClient get _client => _io ??= HttpClient();

  @override
  Future<HttpClientResponse> post(
    String path, {
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    final uri = _resolve(endpoint, path);
    final request = await _client.postUrl(uri);
    headers.forEach(request.headers.set);
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    return HttpClientResponse(
      statusCode: response.statusCode,
      headers: {
        'content-type': response.headers.contentType?.toString() ?? '',
      },
      body: response,
    );
  }

  @override
  Future<HttpClientResponse> get(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final uri = _resolve(endpoint, path);
    final request = await _client.getUrl(uri);
    headers.forEach(request.headers.set);
    final response = await request.close();
    return HttpClientResponse(
      statusCode: response.statusCode,
      headers: {
        'content-type': response.headers.contentType?.toString() ?? '',
      },
      body: response,
    );
  }

  /// Close the underlying `dart:io` client. Once.
  @override
  void close() {
    _io?.close(force: true);
    _io = null;
  }
}

/// [base]/[path] with [path] appended to the base's path, not replacing
/// it: `Uri.resolve` follows RFC 3986 and an absolute path in
/// the reference throws the base's path away — which silently turned every
/// gateway endpoint (`.../api/anthropic`) into a bare origin and 404'd.
/// A trailing slash on the base is tolerated.
Uri _resolve(String base, String path) {
  final b = Uri.parse(base.endsWith('/') ? base : '$base/');
  final ref = Uri.parse(path.startsWith('/') ? path.substring(1) : path);
  return b.resolveUri(ref);
}
