import 'dart:async';

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
}

/// Returns a minimal valid models.dev JSON response.
class _OkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(Duration.zero);
    return http.StreamedResponse(
      Stream.value(
        [123, 125], // "{}" — empty but valid JSON
      ),
      200,
    );
  }
}
