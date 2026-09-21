import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'request_budget.dart';
import 'service.dart';

/// Separate from chat ProviderConfig: no messages, tool schema, temperature,
/// reasoning effort, or output-token ceiling. Credentials are explicitly supplied
/// by composition; this layer never reads global config/environment.
class TypeSafeConfig {
  final String apiKey;
  final String model;
  final Uri endpoint;
  final Duration timeout;
  final int maxResponseBytes;
  final JudgmentRequestBudget requestBudget;

  TypeSafeConfig({
    required this.apiKey,
    this.model = 'jev-latest',
    Uri? endpoint,
    this.timeout = const Duration(seconds: 30),
    this.maxResponseBytes = 8 * 1024 * 1024,
    JudgmentRequestBudget? requestBudget,
  })  : endpoint =
            endpoint ?? Uri.parse('https://api.typesafe.ai/v1/systemone'),
        requestBudget = requestBudget ?? JudgmentRequestBudget(model: model) {
    if (this.requestBudget.model != model) {
      throw ArgumentError('Request budget must target the configured model');
    }
    if (apiKey.trim().isEmpty || RegExp(r'[\x00-\x20\x7f]').hasMatch(apiKey)) {
      throw ArgumentError('TypeSafe requires a nonempty bearer API key');
    }
    if (model.trim().isEmpty)
      throw ArgumentError('TypeSafe model must not be empty');
    final uri = this.endpoint;
    final local = const {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
      throw ArgumentError(
          'TypeSafe endpoint must use HTTPS (or loopback HTTP)');
    }
    if (timeout <= Duration.zero || maxResponseBytes <= 0) {
      throw ArgumentError(
          'TypeSafe timeout and response limit must be positive');
    }
  }
}

/// One HTTP attempt per evaluation. The caller controls retries/concurrency.
/// A fresh owned client per request makes cancellation independent of siblings.
/// Inject a factory returning fresh clients for tests or transport customization.
class TypeSafeJudgmentService implements JudgmentService {
  final TypeSafeConfig config;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final _active = <void Function()>{};
  bool _closed = false;

  TypeSafeJudgmentService({
    required this.config,
    http.Client Function()? clientFactory,
    DateTime Function()? now,
  })  : _clientFactory = clientFactory ?? http.Client.new,
        _now = now ?? DateTime.now;

  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    if (_closed) {
      throw const JudgmentException(JudgmentFailure.closed, attempted: false);
    }
    if (cancellation?.isCancelled ?? false) {
      throw const JudgmentException(JudgmentFailure.cancelled, attempted: false);
    }
    config.requestBudget.check(request);
    final body = jsonEncode(request.toJson(model: config.model));
    final client = _clientFactory();
    final stopped = Completer<JudgmentResult>();
    void stop(JudgmentFailure reason) {
      if (!stopped.isCompleted)
        stopped.completeError(JudgmentException(reason));
    }

    void closeRequest() => stop(JudgmentFailure.closed);
    _active.add(closeRequest);
    final unsubscribe =
        cancellation?.listen(() => stop(JudgmentFailure.cancelled));
    final timer = Timer(config.timeout, () => stop(JudgmentFailure.timeout));
    try {
      return await Future.any([
        _send(client, body, request),
        stopped.future,
      ]);
    } on JudgmentException {
      rethrow;
    } on FormatException {
      throw const JudgmentException(JudgmentFailure.invalidResponse);
    } on http.ClientException {
      throw const JudgmentException(JudgmentFailure.transport);
    } on IOException {
      throw const JudgmentException(JudgmentFailure.transport);
    } finally {
      timer.cancel();
      unsubscribe?.call();
      _active.remove(closeRequest);
      // IOClient.close force-closes active connections, including stalled headers
      // or body reads. Future.any observes their subsequent transport errors.
      client.close();
    }
  }

  Future<JudgmentResult> _send(
      http.Client client, String body, JudgmentRequest request) async {
    final message = http.Request('POST', config.endpoint)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${config.apiKey}',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      })
      ..body = body;
    final response = await client.send(message);
    if (response.statusCode != 200) {
      // Do not retain/echo error bodies; they can contain credentials or state.
      await response.stream.listen((_) {}).cancel();
      throw JudgmentException(
        _httpFailure(response.statusCode),
        statusCode: response.statusCode,
        retryAfter: _retryAfter(response.headers['retry-after']),
      );
    }
    if ((response.contentLength ?? 0) > config.maxResponseBytes) {
      await response.stream.listen((_) {}).cancel();
      throw const JudgmentException(JudgmentFailure.responseTooLarge);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > config.maxResponseBytes) {
        throw const JudgmentException(JudgmentFailure.responseTooLarge);
      }
      bytes.add(chunk);
    }
    return JudgmentResult.fromJson(jsonDecode(utf8.decode(bytes.takeBytes())),
        request: request);
  }

  Duration? _retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
    try {
      final delay = HttpDate.parse(value).difference(_now().toUtc());
      return delay < Duration.zero ? Duration.zero : delay;
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  /// Cancel in-flight evaluations and refuse new ones. Idempotent. Each
  /// evaluation's future settles after its client has been closed in finally.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancel in _active.toList()) {
      cancel();
    }
  }
}

JudgmentFailure _httpFailure(int status) => switch (status) {
      401 => JudgmentFailure.authentication,
      403 => JudgmentFailure.permission,
      400 || 422 => JudgmentFailure.invalidRequest,
      429 => JudgmentFailure.rateLimited,
      >= 500 && <= 599 => JudgmentFailure.unavailable,
      _ => JudgmentFailure.http,
    };
