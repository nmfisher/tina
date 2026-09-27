/// The one real provider: Anthropic's messages API over the wire the
/// sandbox endpoint (`api.z.ai/api/anthropic`) speaks.
///
/// - The HTTP client is injected ([endpoint]); the default is `dart:io`'s
///   own. Tests replay recorded bytes; nothing here opens a socket in a
///   test.
/// - The token comes **from the environment only** (`TINA_LLM_TOKEN` or
///   `ANTHROPIC_API_KEY`), read at construction. It is never written to a
///   file, a log, an error message, or a report. A missing token is a
///   stream error, not a crash.
/// - A stream that stops sending becomes a stream error after [stallTimeout]
///   — the stalls are real; waiting forever is not an option.
/// - Every failure — status, parse, stall, throw — surfaces as
///   [StreamError] in the stream. Nothing throws out of `send`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tina_core/tina_core.dart';

import 'http.dart';
import 'request.dart';
import 'sse.dart';

export 'http.dart';
export 'request.dart';
export 'sse.dart';

/// Where the token and the endpoint come from. Overridable for tests;
/// production never passes it, so nothing but the environment is read.
String? _env(String name) {
  try {
    return Platform.environment[name];
  } catch (_) {
    return null;
  }
}

/// The Anthropic-wire provider.
final class AnthropicProvider extends LlmProvider {
  /// Build from the environment. [tokenFrom] exists so tests can inject a
  /// fake token value without touching the process environment; the
  /// default reads `TINA_LLM_TOKEN`, then `ANTHROPIC_API_KEY`. Null means
  /// every call fails closed with a clear stream error.
  AnthropicProvider({
    required String model,
    HttpEndpoint? endpoint,
    this.stallTimeout = const Duration(seconds: 120),
    String? Function()? tokenFrom,
    String? endpointUrl,
  })  : _endpointOverride = endpoint,
        _endpointUrl = endpointUrl,
        _tokenFrom = tokenFrom ??
            (() => _env('TINA_LLM_TOKEN') ?? _env('ANTHROPIC_API_KEY')),
        super(model);

  /// The messages path on the endpoint.
  static const messagesPath = '/v1/messages';

  final HttpEndpoint? _endpointOverride;
  final String? _endpointUrl;
  final String? Function() _tokenFrom;

  /// How long a silent stream is tolerated before it is declared stalled.
  final Duration stallTimeout;

  HttpEndpoint? _builtEndpoint;

  /// The endpoint: injected, or built from the environment's
  /// `TINA_LLM_ENDPOINT` (falling back to the sandbox's anthropic path).
  /// Built lazily and once.
  HttpEndpoint get endpoint {
    if (_endpointOverride != null) return _endpointOverride;
    return _builtEndpoint ??= IoHttpEndpoint(
      endpoint: _endpointUrl ??
          _env('TINA_LLM_ENDPOINT') ??
          'https://api.z.ai/api/anthropic',
    );
  }

  /// Close the underlying `dart:io` client, when this provider built one.
  @override
  void close() {
    final e = _builtEndpoint;
    if (e is IoHttpEndpoint) e.close();
  }

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    final token = _tokenFrom();
    if (token == null || token.isEmpty) {
      yield const StreamError(
          'no API token: set TINA_LLM_TOKEN or ANTHROPIC_API_KEY in the '
          'environment',
          providerCode: 'no_token');
      return;
    }

    final body = encodeBody(requestBody(
      model: model,
      system: system,
      messages: messages,
      tools: tools,
    ));

    HttpResponse response;
    try {
      response = await endpoint.post(
        messagesPath,
        headers: {
          'content-type': 'application/json',
          'accept': 'text/event-stream',
          // The header the wire expects. The value came from the
          // environment; it is never logged.
          'x-api-key': token,
          'anthropic-version': '2023-06-01',
        },
        body: body,
      );
    } catch (e) {
      // Connection refused, DNS, TLS: the send failed before any body.
      yield StreamError('request failed: transport error ($e)');
      return;
    }

    if (response.statusCode != 200) {
      // The body is JSON, not SSE: an error envelope. Surface its message
      // without leaking the token — only the server's own words come
      // through, truncated.
      final text = await utf8.decoder
          .bind(response.body)
          .fold(StringBuffer(), (b, c) => b..write(c))
          .then((b) => b.toString());
      var message = 'HTTP ${response.statusCode}';
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          final err = decoded['error'];
          if (err is Map<String, dynamic> && err['message'] is String) {
            message = '$message: ${err['message']}';
          } else if (decoded['message'] is String) {
            message = '$message: ${decoded['message']}';
          }
        }
      } catch (_) {
        // Non-JSON error body: the status line alone is the message.
      }
      final requiresUserAction = response.statusCode == 401 ||
          response.statusCode == 403;
      yield StreamError(
        message.length > 500 ? '${message.substring(0, 500)}…' : message,
        statusCode: response.statusCode,
        requiresUserAction: requiresUserAction,
        providerCode:
            response.statusCode == 429 ? 'rate_limited' : null,
        retryAfter: retryAfter(response.headers),
      );
      return;
    }

    // The happy path: an SSE body. Frames become events; a stall or a
    // body error becomes a StreamError; nothing throws out of send.
    final builder = ResponseBuilder();
    final events = <StreamEvent>[];
    final done = _Flag();
    final parser = SseParser(
      onFrame: (frame) {
        if (applyFrame(frame, builder, events)) {
          done.value = true;
          done.sawStop = true;
        }
        // An error frame ends the response too — already yielded.
        if (builder.errored) done.value = true;
      },
      onBadFrame: (problem) {
        builder.badFrame ??= problem;
      },
    );

    // The watchdog and the frame pump are coupled through `done`, so a
    // stall stops the pump and an ended body stops the watchdog.
    yield* _pump(response.body, parser, builder, events, done);
  }

  /// Decode the SSE body into events, yielding each as it is parsed, with
  /// the stall watchdog: any gap longer than [stallTimeout] between chunks
  /// ends the stream with a [StreamError] instead of waiting forever.
  Stream<StreamEvent> _pump(
    Stream<List<int>> body,
    SseParser parser,
    ResponseBuilder builder,
    List<StreamEvent> events,
    _Flag done,
  ) async* {
    final queue = StreamController<StreamEvent>(sync: true);
    final completions = StreamController<StreamEvent>(sync: true);

    Timer? watchdog;
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(stallTimeout, () {
        if (done.value) return;
        done.value = true;
        done.stalled = true;
        queue.add(StreamError('stream stalled: no bytes for $stallTimeout'));
        queue.close();
        completions.close();
      });
    }

    // Pump the body in the background, feeding the parser and forwarding
    // mapped events; the generator consumes the queue with the watchdog
    // armed. This keeps yields incremental: a delta goes out when it
    // arrives, not when the body ends.
    unawaited(() async {
      try {
        resetWatchdog();
        await for (final chunk in body) {
          if (done.value) break;
          resetWatchdog();
          events.clear();
          parser.add(chunk);
          for (final e in events) {
            queue.add(e);
          }
          if (done.value) break; // message_stop seen inside onFrame
        }
        parser.finish();
        watchdog?.cancel();
        // How the body ended decides what completes the stream.
        if (done.stalled) {
          // The watchdog already delivered the stall error.
          return;
        }
        if (builder.badFrame != null) {
          // A bad frame surfaces no matter how the body ended — a clean
          // message_stop followed by junk still gets reported.
          queue.add(StreamError('bad frame in stream: ${builder.badFrame}'));
          return;
        }
        if (done.sawStop && !builder.errored) {
          final completion = builder.build();
          if (completion != null) completions.add(completion);
          return;
        }
        if (builder.errored) {
          // The provider ended the response with an error frame; it was
          // already yielded. No completion is fabricated after it.
          return;
        }
        // The transport closed without an end: not a completion.
        queue.add(StreamError('stream ended before message_stop'));
      } catch (e) {
        queue.add(StreamError('stream failed: $e'));
      } finally {
        watchdog?.cancel();
        await queue.close();
        await completions.close();
      }
    }());

    await for (final e in queue.stream) {
      yield e;
    }
    // Whatever the reason the queue closed, the completions controller
    // closed with it — empty unless a clean stop built one.
    await for (final e in completions.stream) {
      yield e;
    }
  }
}

/// State shared between the watchdog and the frame pump: stop pumping,
/// why, and whether the wire said goodbye.
final class _Flag {
  bool value = false;
  bool sawStop = false;
  bool stalled = false;
}

/// Parse a `Retry-After` header (seconds form only) if present.
Duration? retryAfter(Map<String, String> headers) {
  final v = headers['retry-after'];
  if (v == null) return null;
  final seconds = int.tryParse(v.trim());
  return seconds == null ? null : Duration(seconds: seconds);
}
