/// The HTTP seam. Same idea as `FileSystem`: the real client is `dart:io`'s
/// own, and tests inject a fake that replays recorded bytes — no network,
/// no credentials, no new dependencies.
library;

import 'dart:async';
import 'dart:io';

/// One response the way the caller needs it: status, headers, and the body
/// as a stream of chunks. A streaming SSE response arrives as many chunks
/// over time; a recorded one replays them from a list.
final class HttpResponse {
  const HttpResponse({
    required this.statusCode,
    this.headers = const {},
    Stream<List<int>>? body,
  }) : _body = body;

  final int statusCode;
  final Map<String, String> headers;

  final Stream<List<int>>? _body;

  /// The body bytes, as they arrive.
  Stream<List<int>> get body =>
      _body ?? const Stream<List<int>>.empty();
}

/// POST [path] on the endpoint with [headers] and [body], and hand back the
/// response. The method is fixed because a messages call is always a POST;
/// everything variable travels in the arguments.
abstract class HttpEndpoint {
  Future<HttpResponse> post(
    String path, {
    required Map<String, String> headers,
    required List<int> body,
  });

  /// GET [path] on the endpoint — the catalogue's fetch, and anything
  /// else that only reads.
  Future<HttpResponse> get(
    String path, {
    Map<String, String> headers = const {},
  });
}

/// The real client over `dart:io`'s [HttpClient]. One instance per
/// provider; [close] tears the underlying client down.
final class IoHttpEndpoint implements HttpEndpoint {
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
  Future<HttpResponse> post(
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
    return HttpResponse(
      statusCode: response.statusCode,
      headers: {
        'content-type': response.headers.contentType?.toString() ?? '',
      },
      body: response,
    );
  }

  @override
  Future<HttpResponse> get(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final uri = _resolve(endpoint, path);
    final request = await _client.getUrl(uri);
    headers.forEach(request.headers.set);
    final response = await request.close();
    return HttpResponse(
      statusCode: response.statusCode,
      headers: {
        'content-type': response.headers.contentType?.toString() ?? '',
      },
      body: response,
    );
  }

  /// Close the underlying `dart:io` client. Once.
  void close() {
    _io?.close(force: true);
    _io = null;
  }
}

/// [base]/[path] with [path] appended to the base's path, not replacing
/// it: `Uri.resolve` follows RFC 3986 and an absolute path in the
/// reference throws the base's path away — which silently turned every
/// gateway endpoint (`.../api/anthropic`) into a bare origin and 404'd.
/// A trailing slash on the base is tolerated.
Uri _resolve(String base, String path) {
  final b = Uri.parse(base.endsWith('/') ? base : '$base/');
  final ref = Uri.parse(path.startsWith('/') ? path.substring(1) : path);
  return b.resolveUri(ref);
}
