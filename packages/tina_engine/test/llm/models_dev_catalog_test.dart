import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

class _FailingClient extends http.BaseClient {
  final int statusCode;

  _FailingClient({this.statusCode = 500});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(Duration.zero);
    return http.StreamedResponse(
      Stream.value([0]), // non-null body
      statusCode,
    );
  }
}

class _TimeoutClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Completer<void>().future; // never completes
    throw UnimplementedError();
  }
}

class _CrashClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw http.ClientException('connection refused');
  }
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tina_models_dev_');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// HOME points at the temp dir so load() neither reads the real
  /// ~/.tina/models.dev.json cache nor writes into it.
  ModelsDevCatalog catalog({
    required http.Client httpClient,
    Map<String, String> env = const {},
  }) =>
      ModelsDevCatalog(
        env: {'HOME': tmp.path, ...env},
        client: httpClient,
      );

  group('ModelsDevCatalog.loadWarning', () {
    test('non-null after HTTP error', () async {
      final catalog = ModelsDevCatalog(
        env: const {},
        client: _FailingClient(statusCode: 503),
        fetchTimeout: const Duration(seconds: 5),
        cacheTtl: Duration.zero, // force fetch even if cache file exists
      );
      await catalog.load();
      expect(catalog.loadWarning, contains('HTTP 503'));
    });

    test('non-null after timeout', () async {
      final catalog = ModelsDevCatalog(
        env: const {},
        client: _TimeoutClient(),
        fetchTimeout: const Duration(milliseconds: 1),
        cacheTtl: Duration.zero,
      );
      await catalog.load();
      expect(catalog.loadWarning, isNotNull);
    });

    test('non-null after network error', () async {
      final catalog = ModelsDevCatalog(
        env: const {},
        client: _CrashClient(),
        fetchTimeout: const Duration(seconds: 5),
        cacheTtl: Duration.zero,
      );
      await catalog.load();
      expect(catalog.loadWarning, contains('connection'));
    });

    test('null when disabled via env var (load never called)', () async {
      final catalog = ModelsDevCatalog(
        env: const {'COCOON_MODELS_DEV': '0'},
        client: _FailingClient(),
      );
      // load() would skip because attempt is gated on env at the
      // caller — the catalog itself doesn't check the env var.
      // The warning stays null because _loaded is false.
      expect(catalog.loadWarning, isNull);
    });

    test('loadWarning is null after successful load', () async {
      final catalog = ModelsDevCatalog(
        env: const {},
        client: _OkClient(),
        fetchTimeout: const Duration(seconds: 5),
        cacheTtl: Duration.zero, // skip cache for this test
      );
      await catalog.load();
      expect(catalog.loadWarning, isNull,
          reason: 'successful load should not set a warning');
    });
  });

  group('ModelsDevCatalog.modelsFor unions with the descriptor', () {
    ProviderDescriptor desc(Map<String, ModelInfo> models) =>
        ProviderDescriptor(
          id: 'xiaomi',
          name: 'Xiaomi',
          authSources: const [],
          defaultBaseUrl: 'https://api.xiaomimimo.com/v1',
          builder: (_) => throw UnimplementedError(),
          models: models,
        );

    /// models.json maps "<mdProvider>/<modelId>" → model metadata; xiaomi
    /// has no alias so the tina id is `xiaomi` verbatim.
    ModelsDevCatalog feed(Map<String, Map<String, dynamic>> entries) =>
        catalog(httpClient: _OkClient(jsonEncode(entries)));

    test('a feed model the descriptor lacks is added', () async {
      final c = feed({
        'xiaomi/mimo-v2.5-pro': {
          'name': 'MiMo V2.5 Pro',
          'tool_call': true,
          'limit': {'context': 1048576, 'output': 131072},
        },
      });
      await c.load();
      final d = desc(const {});
      final ids = c.modelsFor(d).map((m) => m.id).toList();
      expect(ids, ['mimo-v2.5-pro']);
    });

    test(
        'a descriptor model the feed lags on stays visible '
        '(regression: xiaomi/mimo-v2.6-flash)', () async {
      final c = feed({
        // Feed knows only the older generation…
        'xiaomi/mimo-v2.5-pro': {
          'name': 'MiMo V2.5 Pro',
          'limit': {'context': 1048576, 'output': 131072},
        },
      });
      await c.load();
      // …but the provider feed (or config `models`) already seeded 2.6.
      final d = desc(const {
        'mimo-v2.6-flash': ModelInfo(
          id: 'mimo-v2.6-flash',
          name: 'MiMo V2.6 Flash',
          contextWindow: 262144,
        ),
      });
      final byId = {for (final m in c.modelsFor(d)) m.id: m};
      expect(byId.keys, containsAll(['mimo-v2.5-pro', 'mimo-v2.6-flash']));
      // Seeded metadata is kept, not replaced by a placeholder.
      expect(byId['mimo-v2.6-flash']!.name, 'MiMo V2.6 Flash');
      expect(byId['mimo-v2.6-flash']!.contextWindow, 262144);
    });

    test('feed metadata wins for a model both sides know', () async {
      final c = feed({
        'xiaomi/mimo-v2.5-pro': {
          'name': 'MiMo V2.5 Pro',
          'tool_call': true,
          'limit': {'context': 1048576, 'output': 131072},
        },
      });
      await c.load();
      final d = desc(const {
        'mimo-v2.5-pro': ModelInfo(
          id: 'mimo-v2.5-pro',
          name: 'stale-name',
          contextWindow: 1024,
        ),
      });
      final byId = {for (final m in c.modelsFor(d)) m.id: m};
      expect(byId['mimo-v2.5-pro']!.name, 'MiMo V2.5 Pro');
      expect(byId['mimo-v2.5-pro']!.contextWindow, 1048576);
      // The union must not duplicate the shared id.
      expect(
          c.modelsFor(d).where((m) => m.id == 'mimo-v2.5-pro'), hasLength(1));
    });

    test('a provider the feed does not know keeps its own map', () async {
      final c = feed({
        'xiaomi/mimo-v2.5-pro': {'name': 'MiMo V2.5 Pro'},
      });
      await c.load();
      final local = ProviderDescriptor(
        id: 'my-ollama',
        name: 'local',
        authSources: const [],
        defaultBaseUrl: 'http://localhost:11434/v1',
        builder: (_) => throw UnimplementedError(),
        models: const {
          'llama3':
              ModelInfo(id: 'llama3', name: 'Llama 3', contextWindow: 8192),
        },
      );
      expect(c.modelsFor(local).map((m) => m.id), ['llama3']);
    });
  });
}

/// Returns a minimal valid models.dev JSON response; an optional body
/// overrides the default `{}`.
class _OkClient extends http.BaseClient {
  _OkClient([this.body = '{}']);

  final String body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(Duration.zero);
    return http.StreamedResponse(
      Stream.value(body.codeUnits),
      200,
    );
  }
}
