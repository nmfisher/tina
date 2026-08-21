import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final _log = Logger('tina.llm');

/// Shared HTTP plumbing used by every LLM provider. Lives in its own file so
/// `openai.dart` doesn't have to reach into `anthropic.dart` for it, and so
/// the transport behaviour (retries, timeouts, error humanization) can be
/// tested in isolation from any specific provider's wire format.

/// Backoff schedule between retries — index 0 is the delay before the FIRST
/// retry. Public because the policy-layer retry ([RetryingProvider]) uses the
/// same schedule the transport-level helper does.
const retryDelays = [
  Duration(milliseconds: 250),
  Duration(milliseconds: 750),
  Duration(milliseconds: 2250),
];

final _random = Random();

/// Equal-jitter backoff: half the base delay plus a uniformly random half.
/// Decorrelates retry timing across concurrent clients so they don't all
/// retry in lockstep against a shared rate-limited provider (thundering herd).
/// Public (with an injectable [rng]) so tests can assert the delay lands
/// within `[base/2, base]` and stays deterministic when seeded.
Duration applyBackoffJitter(Duration base, [Random? rng]) {
  final r = rng ?? _random;
  final half = base.inMilliseconds ~/ 2;
  return Duration(milliseconds: half + r.nextInt(half + 1));
}

/// Cap on how long we'll honor a server's `Retry-After` hint. Anthropic and
/// most providers stay well under this, but we don't want a misconfigured
/// upstream to make us sleep for hours.
const _maxRetryAfter = Duration(seconds: 60);

/// How long to wait for response headers before giving up on a single
/// attempt. The body is then read with a separate stall timeout.
const defaultRequestTimeout = Duration(seconds: 30);

/// Wall-clock between two consecutive SSE events before we treat the stream
/// as dead. Generous enough for slow/long completions; tight enough that a
/// silently-dropped connection doesn't hang the REPL forever.
const defaultStreamIdleTimeout = Duration(seconds: 60);

/// Whether a non-200 status is worth another attempt. Public for the
/// policy-layer retry ([RetryingProvider]), which classifies the StreamError
/// events providers emit.
bool isRetryableStatus(int code) =>
    code == 408 ||
    code == 425 ||
    code == 429 ||
    // Retry 5xx, but skip codes that are structural and won't succeed on
    // retry: 501 Not Implemented, 505 HTTP Version Not Supported.
    (code >= 500 && code < 600 && code != 501 && code != 505);

/// Whether a thrown transport exception may clear on its own (a dropped
/// socket, a reset connection, a header timeout). Providers fold these into
/// `StreamError(transient: true)`; the policy-layer retry re-attempts them.
bool isTransientException(Object e) =>
    e is SocketException || e is HttpException || e is TimeoutException;

/// Parse an HTTP `Retry-After` header value. Accepts integer seconds (the
/// common form for rate-limit responses); ignores HTTP-date form since
/// providers we target don't use it. Returns null if unparseable. Clamps
/// at [_maxRetryAfter] so a misconfigured upstream can't make us sleep
/// for hours.
Duration? parseRetryAfter(String? header) {
  if (header == null) return null;
  final s = header.trim();
  final secs = int.tryParse(s);
  if (secs == null || secs < 0) return null;
  final d = Duration(seconds: secs);
  return d > _maxRetryAfter ? _maxRetryAfter : d;
}

/// Send ONE request attempt — headers timeout, no retry. The LLM providers
/// use this so their wire failures surface as typed [StreamError]s the
/// policy-layer retry ([RetryingProvider]) can classify and re-attempt ABOVE
/// the rate limiter (a retry must re-acquire a launch slot, not bypass the
/// queue the way a transport-internal retry would).
Future<http.StreamedResponse> sendOnce(
  http.Client client,
  http.Request Function() build, {
  Duration requestTimeout = defaultRequestTimeout,
}) {
  // WHY (#23 / #24): a request-timeout must name its knob — one string for
  // two different timeouts sent the operator raising the WRONG flag.
  return client
      .send(build())
      .timeout(
        requestTimeout,
        onTimeout: () => throw TimeoutException(
          'request exceeded ${requestTimeout.inSeconds}s without response '
          'headers — raise with --request-timeout',
          requestTimeout,
        ),
      );
}

/// Send a request, retrying on transient failures with exponential backoff.
/// The request builder closure must produce a fresh Request per attempt —
/// `http.Request` is single-use. Honors a server-supplied `Retry-After`
/// header in preference to the local schedule when present.
///
/// Retries here are TRANSPORT-INTERNAL — invisible to any outer policy — so
/// this is only for utility endpoints (search APIs, fetch). LLM providers
/// must use [sendOnce] + the policy-layer retry instead.
Future<http.StreamedResponse> sendWithRetry(
  http.Client client,
  http.Request Function() build, {
  Duration requestTimeout = defaultRequestTimeout,
}) async {
  for (var attempt = 0;; attempt++) {
    try {
      // Same named-knob message as [sendOnce] (#23): the error must say which
      // timeout tripped, or the operator raises the wrong flag.
      final resp = await client.send(build()).timeout(
        requestTimeout,
        onTimeout: () => throw TimeoutException(
          'request exceeded ${requestTimeout.inSeconds}s without response '
          'headers — raise with --request-timeout',
          requestTimeout,
        ),
      );
      if (isRetryableStatus(resp.statusCode) &&
          attempt < retryDelays.length) {
        await resp.stream.drain();
        final hinted = parseRetryAfter(resp.headers['retry-after']);
        await Future<void>.delayed(hinted ?? applyBackoffJitter(retryDelays[attempt]));
        continue;
      }
      return resp;
    } catch (e) {
      // WHY (#23b): a wall-clock timeout while awaiting response headers is
      // TERMINAL for this loop — the retry schedule (250/750/2250ms) would
      // just re-send the identical oversized payload into the same wall, and
      // a healthy-but-slow prefill reads like a dead provider (4 identical
      // doomed POSTs observed live). Surface as transient anyway so the
      // policy layer / pool fail over with their own cooldown-paced spacing.
      // Socket/HTTP exceptions keep the in-loop retry: those DO clear.
      if (e is TimeoutException) rethrow;
      if (!isTransientException(e) || attempt >= retryDelays.length) {
        rethrow;
      }
      await Future<void>.delayed(applyBackoffJitter(retryDelays[attempt]));
    }
  }
}

/// Turn a provider's HTTP error response into a human-readable single line.
/// Tries the common JSON shapes (`{"error": {"message": ...}}`,
/// `{"message": ...}`) before falling back to a body preview.
String humanizeHttpError(String provider, int status, String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final err = j['error'];
      if (err is Map) {
        final msg = err['message'];
        final type = err['type'];
        if (msg is String) {
          return type is String
              ? '$provider $status ($type): $msg'
              : '$provider $status: $msg';
        }
      }
      if (j['message'] is String) {
        return '$provider $status: ${j['message']}';
      }
    }
  } catch (e) {
    _log.fine('error body not JSON, using preview', e);
  }
  final preview = body.length > 240 ? '${body.substring(0, 240)}…' : body;
  return '$provider $status: $preview';
}

/// Convert a low-level transport exception into a phrase suitable for the
/// user. Falls back to `toString()` for unknown types.
String humanizeException(Object e) {
  if (e is SocketException) {
    return 'Network error: ${e.message}'
        '${e.osError != null ? " (${e.osError!.message})" : ""}';
  }
  if (e is TimeoutException) {
    // WHY (#23 / #24): both knobs collapsed into the same anonymous string.
    // A message set at the raise site (sendOnce / sendWithRetry / stream
    // timeout) carries the knob name; anonymous TimeoutExceptions from
    // elsewhere fall back to the legacy phrase.
    return (e.message ?? '').isNotEmpty
        ? e.message!
        : 'Request timed out';
  }
  return e.toString();
}
