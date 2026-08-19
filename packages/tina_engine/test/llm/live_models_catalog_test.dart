import 'dart:convert';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// [LiveModelsCatalog] — layering each provider's own `GET /v1/models` over
/// the compiled/models.dev catalogs: the live ids are the catalog, metadata
/// comes from the fallback layers, unknown ids get placeholder defaults.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tina_live_models_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  ProviderDescriptor desc({
    String id = 'nim',
    String authVar = 'NVIDIA_API_KEY',
    Map<String, ModelInfo> models = const {},
  }) =>
      ProviderDescriptor(
        id: id,
        name: id,
        authSources: [AuthSource(authVar, AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://example.test',
        builder: (_) => throw UnimplementedError(),
        models: models,
        listsRemoteModels: true,
      );

  /// Serves one canned `/v1/models` JSON body and records requests.
  _RecordingClient client(String body, {int status = 200}) =>
      _RecordingClient(body, status);

  LiveModelsCatalog catalog({
    required Map<String, String> env,
    http.Client? httpClient,
    ModelCatalog? inner,
  }) =>
      LiveModelsCatalog(
        // HOME points at the temp dir so the cache lands in tmp, not ~/.tina.
        env: {'HOME': tmp.path, ...env},
        client: httpClient,
        inner: inner,
      );

  test('live ids become the catalog; known ids keep metadata, new ids get '
      'defaults', () async {
    const compiled = ModelInfo(
      id: 'meta/llama-3.3-70b-instruct',
      name: 'Llama 3.3 70B',
      contextWindow: 131072,
      maxOutput: 4096,
    );
    final d = desc(models: {'meta/llama-3.3-70b-instruct': compiled});
    final c = catalog(
      env: {'NVIDIA_API_KEY': 'k'},
      httpClient: client(jsonEncode({
        'data': [
          {'id': 'brand/new-model'},
          {'id': 'meta/llama-3.3-70b-instruct'},
          // Non-chat entries are filtered out.
          {'id': 'nvidia/nv-embedqa-e5-v5'},
          {'id': 'nvidia/nemotron-3.5-content-safety'},
          {'id': 'nvidia/rerank-qa-mistral'},
        ],
      })),
    );
    await c.load([d]);

    final models = c.modelsFor(d);
    expect(models.map((m) => m.id), [
      'brand/new-model',
      'meta/llama-3.3-70b-instruct',
    ], reason: 'endpoint order, non-chat ids filtered');
    // A compiled id keeps its real metadata.
    final known = models.singleWhere((m) => m.id == compiled.id);
    expect(known.name, 'Llama 3.3 70B');
    expect(known.contextWindow, 131072);
    // An unknown id gets the placeholder defaults.
    final fresh = models.singleWhere((m) => m.id == 'brand/new-model');
    expect(fresh.contextWindow, LiveModelsCatalogPlaceholder.context);
    expect(fresh.maxOutput, LiveModelsCatalogPlaceholder.output);

    // findModel: a live id resolves, a compiled-but-unserved id does not.
    expect(c.findModel(d, compiled.id)?.name, 'Llama 3.3 70B');
    expect(c.findModel(d, 'gone/model'), isNull);
  });

  test('no credentials → no fetch, fallback list unchanged', () async {
    final d = desc();
    final http = client('{"data":[]}');
    final c = catalog(env: {}, httpClient: http);
    await c.load([d]);

    expect(http.requests, isEmpty, reason: 'never hit the endpoint');
    expect(c.modelsFor(d), isEmpty);
  });

  test('a provider that is not listable is skipped', () async {
    final d = ProviderDescriptor(
      id: 'anthropic',
      name: 'Anthropic',
      authSources: const [AuthSource('ANTHROPIC_API_KEY', AuthScheme.apiKeyHeader)],
      defaultBaseUrl: 'https://example.test',
      builder: (_) => throw UnimplementedError(),
    );
    final http = client('{"data":[]}');
    final c = catalog(
      env: {'ANTHROPIC_API_KEY': 'k'},
      httpClient: http,
    );
    await c.load([d]);
    expect(http.requests, isEmpty);
  });

  test('HTTP failure records a warning and falls back to inner/compiled',
      () async {
    final d = desc(models: {
      'a/model': const ModelInfo(
          id: 'a/model', name: 'A', contextWindow: 8, maxOutput: 8),
    });
    final c = catalog(
      env: {'NVIDIA_API_KEY': 'k'},
      httpClient: client('nope', status: 403),
      inner: const CompiledCatalog(),
    );
    await c.load([d]);

    expect(c.loadWarning, contains('HTTP 403'));
    expect(c.modelsFor(d).map((m) => m.id), ['a/model']);
  });

  test('the base URL override env var wins over the default', () async {
    final d = desc();
    final http = client('{"data":[{"id":"x"}]}');
    final c = catalog(
      env: {'NVIDIA_API_KEY': 'k', 'NVIDIA_BASE_URL': 'https://proxy.test'},
      httpClient: http,
    );
    await c.load([d]);

    expect(http.requests.single.url.toString(),
        'https://proxy.test/v1/models');
  });

  test('a fresh cache is used without a fetch', () async {
    final d = desc();
    final cacheDir = Directory('${tmp.path}/.tina/cache/provider_models')
      ..createSync(recursive: true);
    File('${cacheDir.path}/nim.json').writeAsStringSync(jsonEncode({
      'models': ['cached/model'],
    }));
    final http = client('{"data":[]}');

    final c = catalog(env: {'NVIDIA_API_KEY': 'k'}, httpClient: http);
    await c.load([d]);

    expect(http.requests, isEmpty, reason: 'cache hit — no network');
    expect(c.modelsFor(d).map((m) => m.id), ['cached/model']);
  });

  test('an inner catalog (models.dev) supplies metadata for live ids',
      () async {
    final d = desc();
    const fromDev = ModelInfo(
      id: 'dev/model',
      name: 'Dev Model',
      contextWindow: 200000,
      maxOutput: 16000,
    );
    final inner = _StaticCatalog({'nim': [fromDev]});
    final c = catalog(
      env: {'NVIDIA_API_KEY': 'k'},
      httpClient: client(jsonEncode({
        'data': [
          {'id': 'dev/model'},
        ],
      })),
      inner: inner,
    );
    await c.load([d]);

    final m = c.modelsFor(d).single;
    expect(m.name, 'Dev Model');
    expect(m.contextWindow, 200000);
  });
}

class _RecordingClient extends http.BaseClient {
  final String body;
  final int status;
  final requests = <http.Request>[];

  _RecordingClient(this.body, this.status);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
    );
  }
}

class _StaticCatalog implements ModelCatalog {
  final Map<String, List<ModelInfo>> byProvider;
  _StaticCatalog(this.byProvider);

  @override
  List<ModelInfo> modelsFor(ProviderDescriptor desc) =>
      byProvider[desc.id] ?? const [];

  @override
  ModelInfo? findModel(ProviderDescriptor desc, String modelId) {
    for (final m in byProvider[desc.id] ?? const []) {
      if (m.id == modelId) return m;
    }
    return null;
  }

  @override
  bool hasAny(ProviderDescriptor desc) =>
      (byProvider[desc.id] ?? const []).isNotEmpty;

  @override
  String? get loadWarning => null;

  @override
  void close() {}
}

/// Placeholder-constants handle so tests assert against the same numbers the
/// catalog uses, without duplicating them.
abstract final class LiveModelsCatalogPlaceholder {
  static const context = 131072;
  static const output = 8192;
}
