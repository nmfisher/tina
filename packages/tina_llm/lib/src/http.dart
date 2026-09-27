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
}

/// The real client over `dart:io`'s [HttpClient]. One instance per
/// provider; [close] tears the underlying client down.
final class IoHttpEndpoint implements HttpEndpoint {
  IoHttpEndpoint({required this.endpoint});

  /// The absolute origin every [path] is resolved against, e.g.
  /// `https://api.z.ai/api/anthropic`. Read from the environment at
  /// runtime by the provider constructor — never baked into source.
  final String endpoint;

  HttpClient? _io;

  HttpClient get _client => _io ??= HttpClient();

  @override
  Future<HttpResponse> post(
    String path, {
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    final uri = Uri.parse(endpoint).resolve(path);
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

  /// Close the underlying `dart:io` client. Once.
  void close() {
    _io?.close(force: true);
    _io = null;
  }
}
