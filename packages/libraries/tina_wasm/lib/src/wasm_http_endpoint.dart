/// The wasm HTTP port: `tina_core`'s [HttpClientPort] over the `tina:http`
/// host import (see this package's `wit/deps/tina-http`), the interface the
/// Rust host in wasm.dart serves with reqwest.
///
/// The host enforces the capability document's network domain allowlist
/// (docs/engine2-capability-merger.md): an allowed domain sends; an
/// unknown domain returns an approval request, routed through the
/// optional [DomainApprover] (the engine's approval flow) and answered
/// with `respond`. An approved remember-answer widens the host policy
/// through `tina:policy.widen` so later calls to the same domain do not
/// re-ask; persistence stays with the engine's stores. Without an
/// approver an unknown domain fails closed.
///
/// One port instance per provider, like `tina_io`'s `IoHttpEndpoint`: the
/// base URL is constructor state, [path] hangs off it, and the response
/// body is whatever stream the host hands back - chunks arrive as the
/// network delivers them, which is what SSE consumption needs.
library;

import 'package:tina_core/tina_core.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/tina_http.dart' as tina_http;
import 'package:tina_wasm/src/components/tina_policy.dart' as tina_policy;

/// The answer a [DomainApprover] gives for a parked domain approval.
final class DomainApprovalAnswer {
  const DomainApprovalAnswer({required this.allow, this.remember = false});

  final bool allow;

  /// True when the approval flow granted more than this call (an
  /// "always" answer): the host policy widens with the domain.
  final bool remember;
}

/// Routs a parked domain approval through the engine's approval flow.
typedef DomainApprover =
    Future<DomainApprovalAnswer> Function(String url, String reason);

/// [HttpClientPort] over `tina:http`.
final class WasmHttpEndpoint implements HttpClientPort {
  WasmHttpEndpoint({
    required this.endpoint,
    required tina_http.Client client,
    tina_policy.Policy? policy,
    DomainApprover? domainApprover,
  }) : _client = client,
       _policy = policy,
       _domainApprover = domainApprover;

  /// The absolute base every [path] hangs off - see `IoHttpEndpoint` for
  /// why the gateway prefix is the endpoint and how paths resolve.
  final String endpoint;

  final tina_http.Client _client;
  final tina_policy.Policy? _policy;
  final DomainApprover? _domainApprover;

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
    var outcome = await _client.send(
      req: (
        method: method,
        url: _resolve(endpoint, path).toString(),
        headers: [
          for (final entry in headers.entries) (entry.key, entry.value),
        ],
        body: body == null ? cm.Option.none : cm.Option<List<int>>.some(body),
      ),
    );

    // Ride the approval round-trip: an unknown domain parks behind the
    // approver until the host reports sent or denied.
    while (true) {
      switch (outcome) {
        case cm.OkResult(:final value):
          switch (value) {
            case tina_http.TypesOutcomeSent(:final payload):
              final head = payload.head;
              final headerMap = <String, String>{
                for (final (name, headerValue) in head.headers)
                  name: headerValue,
              };
              return HttpClientResponse(
                statusCode: head.status,
                headers: headerMap,
                body: payload.body,
              );
            case tina_http.TypesOutcomeApproval(:final payload):
              final answer = await _ask(payload.url, payload.reason);
              if (answer.remember) {
                await _widen(payload.url);
              }
              outcome = await _client.respond(
                approval: payload.id,
                allow: answer.allow,
              );
            case tina_http.TypesOutcomeDenied(:final payload):
              throw HttpException._('tina:http denied: $payload');
          }
        case cm.ErrorResult(:final value):
          throw HttpException._(
            'tina:http request failed: ${_message(value)}',
          );
      }
    }
  }

  Future<DomainApprovalAnswer> _ask(String url, String reason) async {
    final approver = _domainApprover;
    if (approver == null) {
      // Fail closed: no approval flow, no network.
      return const DomainApprovalAnswer(allow: false);
    }
    return approver(url, reason);
  }

  /// Widens the host policy with the approved domain so later calls do
  /// not re-ask this run. Persistence stays with the engine's stores;
  /// a widening failure cannot retroactively deny the call that was
  /// already approved, so it is reported, not thrown.
  Future<void> _widen(String url) async {
    final policy = _policy;
    if (policy == null) return;
    final uri = Uri.parse(url);
    final domain = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    await policy.widen(
      entry: tina_policy.TypesCapabilityEntry.domain(
        (
          domain: domain,
          origin: 'escalation',
        ),
      ),
    );
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
