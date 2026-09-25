import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:tina/self_update/release_checker.dart';
import 'package:test/test.dart';

/// An [http.Client] serving canned responses by URL path, so the checker's
/// GitHub calls never touch the network.
class _FakeClient extends http.BaseClient {
  _FakeClient(this.routes, {this.headersByPath = const {}});
  final Map<String, (int, String)> routes;

  /// Per-path response headers (retry guidance tests).
  final Map<String, Map<String, String>> headersByPath;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final route = routes[request.url.path];
    final (status, body) = route ?? (404, '');
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {
        const {'content-type': 'application/json'},
        headersByPath[request.url.path] ?? const {},
      }.reduce((a, b) => {...a, ...b}),
    );
  }
}

/// An [http.Client] that always throws — the refused-connection / dead-DNS
/// shape, exercising the checker's network-miss path.
class _ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw const SocketException('Connection refused');
  }
}

String _releaseBody(String tag) => jsonEncode({
  'tag_name': tag,
  'html_url': 'https://github.com/nmfisher/tina/releases/tag/$tag',
  'assets': [
    {
      'name': 'tina-$tag-macos-arm64.tar.gz',
      'browser_download_url':
          'https://example.com/tina-$tag-macos-arm64.tar.gz',
    },
    {
      'name': 'tina-$tag-macos-arm64.tar.gz.sha256',
      'browser_download_url':
          'https://example.com/tina-$tag-macos-arm64.tar.gz.sha256',
    },
  ],
});

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('tina_release_check_');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Map<String, String> env() => {'HOME': home.path};

  group('isNewer', () {
    test('major/minor/patch each trigger', () {
      expect(isNewer('v0.2.0', current: '0.1.4'), isTrue);
      expect(isNewer('v1.0.0', current: '0.1.4'), isTrue);
      expect(isNewer('v0.1.5', current: '0.1.4'), isTrue);
    });

    test('equal or older is not newer', () {
      expect(isNewer('v0.1.4', current: '0.1.4'), isFalse);
      expect(isNewer('0.1.3', current: 'v0.1.4'), isFalse);
    });

    test('unparsable tags never compare newer', () {
      expect(isNewer('banana', current: '0.1.4'), isFalse);
      expect(isNewer('', current: '0.1.4'), isFalse);
      expect(isNewer('v0.1.4', current: 'banana'), isFalse);
    });

    test('pre-release suffixes are ignored', () {
      expect(isNewer('v0.2.0-rc.1', current: '0.1.4'), isTrue);
      expect(isNewer('v0.1.4-dev.9', current: '0.1.4'), isFalse);
    });
  });

  group('fetchLatest', () {
    test('parses tag and asset download URLs', () async {
      final client = _FakeClient({
        '/repos/nmfisher/tina/releases/latest': (200, _releaseBody('v0.2.0')),
      });
      final checker = ReleaseChecker(env: env(), client: client);
      addTearDown(checker.close);

      final release = await checker.fetchLatest();
      expect(release, isNotNull);
      expect(release!.tag, 'v0.2.0');
      expect(release.version, '0.2.0');
      expect(
        release.releaseUrl,
        'https://github.com/nmfisher/tina/releases/tag/v0.2.0',
      );
      expect(
        release.assetUrls['tina-v0.2.0-macos-arm64.tar.gz'],
        'https://example.com/tina-v0.2.0-macos-arm64.tar.gz',
      );
      expect(
        release.assetUrls['tina-v0.2.0-macos-arm64.tar.gz.sha256'],
        'https://example.com/tina-v0.2.0-macos-arm64.tar.gz.sha256',
      );
    });

    test('non-200 and malformed payloads are null, not errors', () async {
      for (final body in [
        (500, '{}'),
        (200, 'not json'),
        (200, jsonEncode({'assets': []})), // no tag_name
      ]) {
        final client = _FakeClient({
          '/repos/nmfisher/tina/releases/latest': body,
        });
        final checker = ReleaseChecker(env: env(), client: client);
        addTearDown(checker.close);
        expect(await checker.fetchLatest(), isNull, reason: '$body');
      }
    });
  });

  group('cache', () {
    test(
      'checkCached answers from a fresh cache without the network',
      () async {
        // Seed the cache directly (a previous run's fetchLatest wrote it).
        final cacheDir = Directory(p.join(home.path, '.tina', 'cache'))
          ..createSync(recursive: true);
        File(p.join(cacheDir.path, 'latest_release.json')).writeAsStringSync(
          jsonEncode(
            ReleaseInfo(
              tag: 'v0.3.0',
              releaseUrl: 'https://example.com/rel',
              assetUrls: const {},
            ).toJson(),
          ),
        );

        // No routes at all: any request would 404 (and be null).
        final client = _FakeClient({});
        final checker = ReleaseChecker(env: env(), client: client);
        addTearDown(checker.close);

        final release = await checker.checkCached();
        expect(release?.tag, 'v0.3.0');
        expect(
          client.requests,
          isEmpty,
          reason: 'a fresh cache must not hit the network',
        );
      },
    );

    test('an expired cache refetches and rewrites', () async {
      final cacheDir = Directory(p.join(home.path, '.tina', 'cache'))
        ..createSync(recursive: true);
      final cacheFile = File(p.join(cacheDir.path, 'latest_release.json'))
        ..writeAsStringSync(
          jsonEncode(
            ReleaseInfo(
              tag: 'v0.0.1',
              releaseUrl: '',
              assetUrls: const {},
            ).toJson(),
          ),
        );
      // Backdate past the TTL.
      cacheFile.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 2)),
      );

      final client = _FakeClient({
        '/repos/nmfisher/tina/releases/latest': (200, _releaseBody('v0.4.0')),
      });
      final checker = ReleaseChecker(
        env: env(),
        client: client,
        cacheTtl: const Duration(hours: 1),
      );
      addTearDown(checker.close);

      expect((await checker.checkCached())?.tag, 'v0.4.0');
      final reread = ReleaseInfo.fromJson(
        jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>,
      );
      expect(reread.tag, 'v0.4.0');
    });

    test('a successful fetch writes the cache', () async {
      final client = _FakeClient({
        '/repos/nmfisher/tina/releases/latest': (200, _releaseBody('v0.5.0')),
      });
      final checker = ReleaseChecker(env: env(), client: client);
      addTearDown(checker.close);

      await checker.checkCached();
      final cacheFile = File(
        p.join(home.path, '.tina', 'cache', 'latest_release.json'),
      );
      expect(cacheFile.existsSync(), isTrue);
      final reread = ReleaseInfo.fromJson(
        jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>,
      );
      expect(reread.tag, 'v0.5.0');
    });
  });

  group('checkWithRevalidate', () {
    test(
      'a fresh cache naming a newer release short-circuits, no network',
      () async {
        final cacheDir = Directory(p.join(home.path, '.tina', 'cache'))
          ..createSync(recursive: true);
        File(p.join(cacheDir.path, 'latest_release.json')).writeAsStringSync(
          jsonEncode(
            ReleaseInfo(
              tag: 'v9.9.9',
              releaseUrl: 'https://example.com/rel',
              assetUrls: const {},
            ).toJson(),
          ),
        );

        final client = _FakeClient({});
        final checker = ReleaseChecker(env: env(), client: client);
        addTearDown(checker.close);

        expect((await checker.checkWithRevalidate())?.tag, 'v9.9.9');
        expect(
          client.requests,
          isEmpty,
          reason: 'a cached newer release needs no revalidation',
        );
      },
    );

    test(
      'a cached not-newer answer revalidates and adopts the fresh release',
      () async {
        // The 0.8.30 silent-miss shape: the cache predates the release, which
        // published inside the TTL window, so the cache alone never sees it.
        final cacheDir = Directory(p.join(home.path, '.tina', 'cache'))
          ..createSync(recursive: true);
        final cacheFile = File(p.join(cacheDir.path, 'latest_release.json'))
          ..writeAsStringSync(
            jsonEncode(
              ReleaseInfo(
                tag: 'v0.0.1',
                releaseUrl: '',
                assetUrls: const {},
              ).toJson(),
            ),
          );

        final client = _FakeClient({
          '/repos/nmfisher/tina/releases/latest': (200, _releaseBody('v9.9.9')),
        });
        final checker = ReleaseChecker(env: env(), client: client);
        addTearDown(checker.close);

        expect((await checker.checkWithRevalidate())?.tag, 'v9.9.9');
        final reread = ReleaseInfo.fromJson(
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>,
        );
        expect(
          reread.tag,
          'v9.9.9',
          reason: 'the revalidation rewrites the cache',
        );
      },
    );

    test(
      'a network miss during revalidation falls back to the cache',
      () async {
        final cacheDir = Directory(p.join(home.path, '.tina', 'cache'))
          ..createSync(recursive: true);
        File(p.join(cacheDir.path, 'latest_release.json')).writeAsStringSync(
          jsonEncode(
            ReleaseInfo(
              tag: 'v0.3.0',
              releaseUrl: '',
              assetUrls: const {},
            ).toJson(),
          ),
        );

        final client = _FakeClient({
          '/repos/nmfisher/tina/releases/latest': (500, ''),
        });
        final checker = ReleaseChecker(env: env(), client: client);
        addTearDown(checker.close);

        expect(
          (await checker.checkWithRevalidate())?.tag,
          'v0.3.0',
          reason: 'the cached value stays the best-known answer',
        );
        expect(
          checker.lastMiss?.status,
          500,
          reason: 'the miss stays recorded — the fallback answer is stale',
        );
      },
    );

    test('neither cache nor network knows: null', () async {
      final client = _FakeClient({
        '/repos/nmfisher/tina/releases/latest': (500, ''),
      });
      final checker = ReleaseChecker(env: env(), client: client);
      addTearDown(checker.close);

      expect(await checker.checkWithRevalidate(), isNull);
    });
  });

  group('miss visibility', () {
    test('a 403 is recorded as a rate-limited miss', () async {
      final client = _FakeClient({
        '/repos/nmfisher/tina/releases/latest': (
          403,
          '{"message":"API rate limit exceeded"}',
        ),
      });
      final checker = ReleaseChecker(env: env(), client: client);
      addTearDown(checker.close);

      expect(await checker.checkWithRevalidate(), isNull);
      final miss = checker.lastMiss;
      expect(miss, isNotNull);
      expect(miss!.rateLimited, isTrue);
      expect(miss.toString(), 'HTTP 403');
    });

    test(
      'a timeout/connection failure is recorded as a network miss',
      () async {
        // A client that throws, the way a refused connection or a request
        // past the timeout surfaces — not an HTTP status at all.
        final checker = ReleaseChecker(env: env(), client: _ThrowingClient());
        addTearDown(checker.close);

        expect(await checker.checkWithRevalidate(), isNull);
        final miss = checker.lastMiss;
        expect(miss, isNotNull);
        expect(miss!.kind, MissKind.network);
        expect(miss.rateLimited, isFalse);
        expect(miss.detail, isNotEmpty);
      },
    );

    test('a successful fetch clears the miss', () async {
      final checker = ReleaseChecker(
        env: env(),
        client: _FakeClient({
          '/repos/nmfisher/tina/releases/latest': (200, _releaseBody('v0.2.0')),
        }),
      );
      addTearDown(checker.close);

      await checker.fetchLatest();
      expect(checker.lastMiss, isNull);
    });

    test('a missing tag_name is a badPayload miss', () async {
      final checker = ReleaseChecker(
        env: env(),
        client: _FakeClient({
          '/repos/nmfisher/tina/releases/latest': (
            200,
            jsonEncode({'assets': []}),
          ),
        }),
      );
      addTearDown(checker.close);

      await checker.fetchLatest();
      expect(checker.lastMiss?.kind, MissKind.badPayload);
    });
  });

  group('rate-limit backoff', () {
    test(
      'a 403 with x-ratelimit-reset defers probes until the reset',
      () async {
        final resetAt = DateTime.now().add(const Duration(minutes: 30));
        final client = _FakeClient(
          {'/repos/nmfisher/tina/releases/latest': (403, 'rate limited')},
          headersByPath: {
            '/repos/nmfisher/tina/releases/latest': {
              'x-ratelimit-reset': (resetAt.millisecondsSinceEpoch ~/ 1000)
                  .toString(),
            },
          },
        );
        final checker = ReleaseChecker(env: env(), client: client);
        addTearDown(checker.close);

        expect(await checker.checkWithRevalidate(), isNull);
        expect(checker.lastMiss?.rateLimited, isTrue);

        // The window is recorded and open: a background check now probes
        // nothing and falls back to the (empty) cache.
        expect(checker.deferUntil, isNotNull);
        final before = client.requests.length;
        expect(await checker.checkWithRevalidate(), isNull);
        expect(client.requests.length, before);
      },
    );

    test(
      'the recorded defer window survives a new checker (restart)',
      () async {
        final resetAt = DateTime.now().add(const Duration(minutes: 30));
        final first = ReleaseChecker(
          env: env(),
          client: _FakeClient(
            {'/repos/nmfisher/tina/releases/latest': (403, 'rate limited')},
            headersByPath: {
              '/repos/nmfisher/tina/releases/latest': {
                'x-ratelimit-reset': (resetAt.millisecondsSinceEpoch ~/ 1000)
                    .toString(),
              },
            },
          ),
        );
        addTearDown(first.close);
        expect(await first.checkWithRevalidate(), isNull);
        expect(first.deferUntil, isNotNull);

        // A brand-new checker — the restart shape — reads the same window.
        final client2 = _FakeClient({});
        final second = ReleaseChecker(env: env(), client: client2);
        addTearDown(second.close);
        expect(
          second.deferUntil,
          isNotNull,
          reason: 'the defer window persists in the tina cache dir',
        );
        expect(await second.checkWithRevalidate(), isNull);
        expect(
          client2.requests,
          isEmpty,
          reason: 'a deferred background check must not touch the network',
        );
      },
    );

    test('retry-after is honored and capped at maxBackoff', () async {
      final farFuture = DateTime.now().add(const Duration(days: 3));
      final checker = ReleaseChecker(
        env: env(),
        client: _FakeClient(
          {'/repos/nmfisher/tina/releases/latest': (503, 'overloaded')},
          headersByPath: {
            '/repos/nmfisher/tina/releases/latest': {
              'retry-after': '999999', // ~11.5 days, way past the cap.
            },
          },
        ),
      );
      addTearDown(checker.close);

      await checker.fetchLatest();
      final until = checker.deferUntil!;
      final capped = DateTime.now().add(ReleaseChecker.maxBackoff);
      expect(
        until.isBefore(capped.add(const Duration(minutes: 1))),
        isTrue,
        reason: 'a far-future retry-after is capped, not honored verbatim',
      );
      expect(until.isAfter(DateTime.now()), isTrue);
      // Silence the unused warning for the far-future value; it documents
      // what the server claimed.
      expect(farFuture.isAfter(until), isTrue);
    });

    test('an expired window re-opens probing (window clears itself)', () async {
      final checker = ReleaseChecker(env: env(), client: _FakeClient({}));
      addTearDown(checker.close);
      await checker.deferUntilForTest(
        DateTime.now().subtract(const Duration(minutes: 1)),
      );

      expect(
        checker.deferUntil,
        isNull,
        reason: 'a past deadline reads as no window',
      );
      // No routes: if it probed it would 404-miss; either way it must not
      // skip silently.
      expect(await checker.checkWithRevalidate(), isNull);
    });

    test('a successful fetch clears the defer window', () async {
      final checker = ReleaseChecker(env: env(), client: _FakeClient({}));
      addTearDown(checker.close);
      await checker.deferUntilForTest(
        DateTime.now().add(const Duration(hours: 1)),
      );
      expect(checker.deferUntil, isNotNull);

      // `/update` semantics: fetchLatest ignores the gate. The two checkers
      // share the cache dir, so the success resolves the window for both —
      // its premise (the network was failing) no longer holds. That is the
      // point of persisting the window rather than keeping it in-memory.
      final forced = ReleaseChecker(
        env: env(),
        client: _FakeClient({
          '/repos/nmfisher/tina/releases/latest': (200, _releaseBody('v0.2.0')),
        }),
      );
      addTearDown(forced.close);
      expect(await forced.fetchLatest(), isNotNull);
      expect(
        checker.deferUntil,
        isNull,
        reason: 'a success anywhere clears the shared window',
      );
      expect(forced.deferUntil, isNull);
    });

    test('a probe skipped by the window leaves lastMiss untouched', () async {
      final resetAt = DateTime.now().add(const Duration(minutes: 30));
      final checker = ReleaseChecker(
        env: env(),
        client: _FakeClient(
          {'/repos/nmfisher/tina/releases/latest': (403, 'rate limited')},
          headersByPath: {
            '/repos/nmfisher/tina/releases/latest': {
              'x-ratelimit-reset': (resetAt.millisecondsSinceEpoch ~/ 1000)
                  .toString(),
            },
          },
        ),
      );
      addTearDown(checker.close);
      await checker.fetchLatest(); // records the miss + window
      final miss = checker.lastMiss;
      expect(miss, isNotNull);

      expect(await checker.checkWithRevalidate(), isNull);
      expect(
        checker.lastMiss,
        same(miss),
        reason: 'the skipped probe fabricates no fresh failure',
      );
    });
  });

  test('ReleaseInfo toJson/fromJson round-trips', () {
    final info = ReleaseInfo(
      tag: 'v1.2.3',
      releaseUrl: 'https://example.com',
      assetUrls: const {'a.tar.gz': 'https://example.com/a.tar.gz'},
    );
    final copy = ReleaseInfo.fromJson(
      jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>,
    );
    expect(copy.tag, 'v1.2.3');
    expect(copy.releaseUrl, 'https://example.com');
    expect(copy.assetUrls['a.tar.gz'], 'https://example.com/a.tar.gz');
  });
}
