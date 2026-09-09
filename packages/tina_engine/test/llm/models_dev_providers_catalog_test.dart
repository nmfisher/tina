import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// A minimal `api.json`: one OpenAI-compatible provider with a base URL and
/// two models (one limited, one not — and with a slash in its id), plus one
/// provider models.dev records no base URL for.
const _payload = {
  'moonshotai': {
    'id': 'moonshotai',
    'name': 'Moonshot AI',
    'env': ['MOONSHOT_API_KEY'],
    'npm': '@ai-sdk/openai-compatible',
    'doc': 'https://platform.moonshot.ai/docs',
    'api': 'https://api.moonshot.ai/v1',
    'models': {
      'kimi-k2': {
        'id': 'kimi-k2',
        'name': 'Kimi K2',
        'tool_call': true,
        'modalities': {
          'input': ['text', 'image'],
        },
        'limit': {'context': 262144, 'output': 16384},
      },
      'kimi-k1/no-limit': {
        'id': 'kimi-k1/no-limit',
        'name': 'Kimi K1',
      },
    },
  },
  'local-ish': {
    'id': 'local-ish',
    'name': 'Local-ish',
    'env': [],
    'npm': '@ai-sdk/openai-compatible',
    'models': {
      'x': {'id': 'x', 'name': 'X'},
    },
  },
};

class _JsonClient extends http.BaseClient {
  _JsonClient(this.body, {this.statusCode = 200});

  final Map<String, dynamic> body;
  final int statusCode;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      statusCode,
    );
  }
}

class _TimeoutClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future; // never completes
}

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('tina-mdprov-');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Map<String, String> env() => {'HOME': home.path};

  File cacheFile() => File(p.join(
      home.path, '.tina', 'cache', 'models.dev.providers.json'));

  group('ModelsDevProviderCatalog.refresh', () {
    test('parses providers, credentials, base URLs and per-model metadata',
        () async {
      final catalog = ModelsDevProviderCatalog(
        env: env(),
        client: _JsonClient(_payload),
      );
      await catalog.refresh();

      expect(catalog.loadWarning, isNull);
      expect(catalog.refreshPending, isFalse);
      expect(catalog.cachedAt, isNotNull);
      expect(catalog.providers.keys, containsAll(['moonshotai', 'local-ish']));

      final moonshot = catalog.providers['moonshotai']!;
      expect(moonshot.key, 'moonshotai');
      expect(moonshot.name, 'Moonshot AI');
      expect(moonshot.npm, '@ai-sdk/openai-compatible');
      expect(moonshot.apiBase, 'https://api.moonshot.ai/v1');
      expect(moonshot.envVars, ['MOONSHOT_API_KEY']);

      final k2 = moonshot.models['kimi-k2']!;
      expect(k2.name, 'Kimi K2');
      expect(k2.contextWindow, 262144);
      expect(k2.maxOutput, 16384);
      expect(k2.supportsTools, isTrue);
      expect(k2.supportsVision, isTrue);

      // A slash in the model id is data, not a namespace split.
      final k1 = moonshot.models['kimi-k1/no-limit']!;
      expect(k1.name, 'Kimi K1');
      // Missing `limit` → documented placeholders, never a dropped entry.
      expect(k1.contextWindow, modelsDevDefaultContextWindow);
      expect(k1.maxOutput, modelsDevDefaultMaxOutput);

      // No `api` recorded → apiBase stays null (the seed skips these).
      expect(catalog.providers['local-ish']!.apiBase, isNull);
    });

    test('writes the cache file it will seed from next launch', () async {
      final catalog = ModelsDevProviderCatalog(
        env: env(),
        client: _JsonClient(_payload),
      );
      await catalog.refresh();

      expect(cacheFile().existsSync(), isTrue);
      final raw = jsonDecode(cacheFile().readAsStringSync());
      expect(raw, isA<Map<String, dynamic>>());
      expect((raw as Map).keys, contains('moonshotai'));
    });

    test('HTTP error sets loadWarning and leaves refreshPending true',
        () async {
      final catalog = ModelsDevProviderCatalog(
        env: env(),
        client: _JsonClient(const {}, statusCode: 500),
      );
      await catalog.refresh();

      expect(catalog.loadWarning, contains('HTTP 500'));
      expect(catalog.refreshPending, isTrue);
      expect(catalog.providers, isEmpty);
    });

    test('a timeout is a warning, not a throw', () async {
      final catalog = ModelsDevProviderCatalog(
        env: env(),
        client: _TimeoutClient(),
        fetchTimeout: const Duration(milliseconds: 1),
      );
      await catalog.refresh();

      expect(catalog.loadWarning, contains('models.dev provider list'));
      expect(catalog.refreshPending, isTrue);
    });

    test('refreshPending is true while a refresh is in flight', () async {
      final catalog = ModelsDevProviderCatalog(
        env: env(),
        client: _TimeoutClient(),
      );
      // Deliberately not awaited: the request never completes, so the only
      // observable is the flag the settings row reads.
      catalog.refresh();
      expect(catalog.refreshPending, isTrue);
      expect(catalog.loadWarning, isNull, reason: 'not failed — just running');
    });
  });

  group('ModelsDevProviderCatalog.loadFromCache', () {
    test('seeds from a cache of ANY age', () async {
      cacheFile().parent.createSync(recursive: true);
      cacheFile().writeAsStringSync(jsonEncode(_payload));
      // Providers change slowly: a cache from months ago must still seed
      // deterministically rather than waiting on the network at startup.
      final old = DateTime.now().subtract(const Duration(days: 90));
      cacheFile().setLastModifiedSync(old);

      final catalog = ModelsDevProviderCatalog(
        env: env(),
        client: _JsonClient(const {}),
      );
      await catalog.loadFromCache();

      expect(catalog.providers['moonshotai']!.apiBase,
          'https://api.moonshot.ai/v1');
      expect(catalog.cachedAt, isNotNull);
      expect(catalog.cachedAt!.isBefore(old.add(const Duration(minutes: 1))),
          isTrue,
          reason: 'cachedAt is the cache file mtime, not "now"');
    });

    test('a missing cache seeds nothing and reports no age', () async {
      final catalog = ModelsDevProviderCatalog(
        env: env(),
        client: _JsonClient(_payload),
      );
      await catalog.loadFromCache();

      expect(catalog.providers, isEmpty);
      expect(catalog.cachedAt, isNull);
      expect(catalog.refreshPending, isFalse);
    });

    test('an unreadable cache is non-fatal', () async {
      cacheFile().parent.createSync(recursive: true);
      cacheFile().writeAsStringSync('{not json');

      final catalog = ModelsDevProviderCatalog(
        env: env(),
        client: _JsonClient(_payload),
      );
      await catalog.loadFromCache();

      expect(catalog.providers, isEmpty);
      expect(catalog.loadWarning, isNull, reason: 'parse failure is not a load failure');
    });
  });
}
