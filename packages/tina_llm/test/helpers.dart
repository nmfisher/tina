// Shared test doubles: an endpoint that records the request and replays
// canned bytes, plus SSE frame helpers. No network, no credentials —
// tokens in tests are literals handed to the injected closure.
library;

import 'dart:async';
import 'dart:convert';

import 'package:tina_llm/tina_llm.dart';

/// A canned response: status, headers, body chunks.
HttpResponse sseResponse(int status, List<String> chunks,
        {Map<String, String> headers = const {}}) =>
    HttpResponse(
      statusCode: status,
      headers: headers,
      body: Stream.fromIterable([
        for (final c in chunks) utf8.encode(c),
      ]),
    );

/// An endpoint that records the request and replays [response].
final class ReplayEndpoint implements HttpEndpoint {
  ReplayEndpoint(this.response);

  final HttpResponse response;
  String? path;
  Map<String, String>? headers;
  Map<String, dynamic>? body;

  @override
  Future<HttpResponse> post(
    String path, {
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    this.path = path;
    this.headers = headers;
    this.body = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    return response;
  }

  @override
  Future<HttpResponse> get(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    this.path = path;
    this.headers = headers;
    return response;
  }
}

/// SSE frames as the wires send them: `event:` line, `data:` line, blank.
String sseFrame(String type, Map<String, dynamic> data) =>
    'event: $type\ndata: ${jsonEncode(data)}\n\n';
