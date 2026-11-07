/// The wasm HTTP port: `tina_core`'s [HttpClientPort] over the `tina:http`
/// host import (see this package's `wit/deps/tina-http`), the interface the
/// Rust host in wasm.dart serves with reqwest.
///
/// One port instance per provider, like `tina_io`'s `IoHttpEndpoint`: the
/// base URL is constructor state, [path] hangs off it, and the response
/// body is whatever stream the host hands back - chunks arrive as the
/// network delivers them, which is what SSE consumption needs.
library;

import 'package:tina_core/tina_core.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/tina_http.dart' as tina_http;

/// [HttpClientPort] over `tina:http`.
final class WasmHttpEndpoint implements HttpClientPort {
  WasmHttpEndpoint({required this.endpoint, required tina_http.Client client})
      : _client = client;

  /// The absolute base every [path] hangs off - see `IoHttpEndpoint` for
  /// why the gateway prefix is the endpoint and how paths resolve.
  final String endpoint;

  final tina_http.Client _client;

  @override
  Future<HttpClientResponse> post(
    String path, {
    required Map<String, String> headers,
    required List<int> body,
  }) => _send('POST', path, headers, body);

  @override
  Future<HttpClientResponse> get(
    String path, {
    Map<String, String> headers = const {},
  }) => _send('GET', path, headers, null);

  @override
  void close() {
    // The host client outlives every endpoint: requests are issued per
    // call, so there is no per-endpoint resource to release.
  }

  Future<HttpClientResponse> _send(
    String method,
    String path,
    Map<String, String> headers,
    List<int>? body,
  ) async {
    final result = await _client.send(
      req: (
        method: method,
        url: _resolve(endpoint, path).toString(),
        headers: [
          for (final entry in headers.entries) (entry.key, entry.value),
        ],
        body: body == null ? cm.Option.none : cm.Option<List<int>>.some(body),
      ),
    );

    switch (result) {
      case cm.OkResult(:final value):
        final (:status, :headers) = value.$1;
        final headerMap = <String, String>{
          for (final (name, headerValue) in headers) name: headerValue,
        };
        return HttpClientResponse(
          statusCode: status,
          headers: headerMap,
          body: value.$2,
        );
      case cm.ErrorResult(:final value):
        throw HttpException._(
          'tina:http request failed: ${_message(value)}',
        );
    }
  }

  static String _message(tina_http.TypesError error) {
    return switch (error) {
      tina_http.TypesErrorMessage(:final payload) => payload,
    };
  }
}

/// A transport-level failure, mirroring what `dart:io` throws from
/// [HttpClient] connection errors: callers catch generically, the engine
/// turns the message into a stream error.
final class HttpException implements Exception {
  HttpException._(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [base]/[path] with [path] appended to the base's path, not replacing
/// it - the same resolution `IoHttpEndpoint` does (an RFC 3986 resolve
/// with an absolute reference path would throw the base's path away).
Uri _resolve(String base, String path) {
  final b = Uri.parse(base.endsWith('/') ? base : '$base/');
  final ref = Uri.parse(path.startsWith('/') ? path.substring(1) : path);
  return b.resolveUri(ref);
}
