import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Captured outgoing request details, populated by [CapturingClient]. Used by
/// encode-side provider tests to assert on what was sent.
class CapturedRequest {
  String? body;
  String? url;
  Map<String, String> headers = const {};
  late final http.Client client = CapturingClient(this);
}

/// An [http.Client] that records the request body/URL/headers into [sink] and
/// returns an empty SSE stream. The empty stream is enough to drain a
/// provider's `send` so the caller can assert on the captured request without
/// standing up a real response; tests that need a scripted response use
/// [ScriptedSseClient] instead.
class CapturingClient extends http.BaseClient {
  final CapturedRequest sink;
  CapturingClient(this.sink);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      sink.body = request.body;
      sink.url = request.url.toString();
      sink.headers = request.headers;
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('')),
      200,
      headers: const {'content-type': 'text/event-stream'},
    );
  }
}

/// An [http.Client] that returns a fixed SSE body (and status) on every `send`,
/// for parse-side provider tests.
class ScriptedSseClient extends http.BaseClient {
  final String body;
  final int status;
  ScriptedSseClient(this.body, {this.status = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: const {'content-type': 'text/event-stream'},
    );
  }
}

/// An [http.Client] whose stream emits nothing but delays forever —
/// the provider's stream-idle timeout should fire. We use a controller
/// that never emits; the underlying stream is open but silent.
class SilentSseClient extends http.BaseClient {
  SilentSseClient();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    // Intentionally never emit and never close — the stream stays open
    // but silent, so the provider's .timeout() measures from the open time.
    return http.StreamedResponse(
      controller.stream,
      200,
      headers: const {'content-type': 'text/event-stream'},
    );
  }
}
