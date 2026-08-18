import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:tina/self_update/release_checker.dart';
import 'package:test/test.dart';

/// An [http.Client] serving canned responses by URL path, so the checker's
/// GitHub calls never touch the network.
class _FakeClient extends http.BaseClient {
  _FakeClient(this.routes);
  final Map<String, (int, String)> routes;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final route = routes[request.url.path];
    final (status, body) = route ?? (404, '');
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: const {'content-type': 'application/json'},
    );
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
      expect(release.releaseUrl,
          'https://github.com/nmfisher/tina/releases/tag/v0.2.0');
      expect(release.assetUrls['tina-v0.2.0-macos-arm64.tar.gz'],
          'https://example.com/tina-v0.2.0-macos-arm64.tar.gz');
      expect(release.assetUrls['tina-v0.2.0-macos-arm64.tar.gz.sha256'],
          'https://example.com/tina-v0.2.0-macos-arm64.tar.gz.sha256');
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
    test('checkCached answers from a fresh cache without the network',
        () async {
      // Seed the cache directly (a previous run's fetchLatest wrote it).
      final cacheDir = Directory(p.join(home.path, '.tina', 'cache'))
        ..createSync(recursive: true);
      File(p.join(cacheDir.path, 'latest_release.json'))
          .writeAsStringSync(jsonEncode(ReleaseInfo(
        tag: 'v0.3.0',
        releaseUrl: 'https://example.com/rel',
        assetUrls: const {},
      ).toJson()));

      // No routes at all: any request would 404 (and be null).
      final client = _FakeClient({});
      final checker = ReleaseChecker(env: env(), client: client);
      addTearDown(checker.close);

      final release = await checker.checkCached();
      expect(release?.tag, 'v0.3.0');
      expect(client.requests, isEmpty,
          reason: 'a fresh cache must not hit the network');
    });

    test('an expired cache refetches and rewrites', () async {
      final cacheDir = Directory(p.join(home.path, '.tina', 'cache'))
        ..createSync(recursive: true);
      final cacheFile = File(p.join(cacheDir.path, 'latest_release.json'))
        ..writeAsStringSync(jsonEncode(
            ReleaseInfo(tag: 'v0.0.1', releaseUrl: '', assetUrls: const {})
                .toJson()));
      // Backdate past the TTL.
      cacheFile.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 2)));

      final client = _FakeClient({
        '/repos/nmfisher/tina/releases/latest': (200, _releaseBody('v0.4.0')),
      });
      final checker = ReleaseChecker(
          env: env(), client: client, cacheTtl: const Duration(hours: 1));
      addTearDown(checker.close);

      expect((await checker.checkCached())?.tag, 'v0.4.0');
      final reread = ReleaseInfo.fromJson(
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>);
      expect(reread.tag, 'v0.4.0');
    });

    test('a successful fetch writes the cache', () async {
      final client = _FakeClient({
        '/repos/nmfisher/tina/releases/latest': (200, _releaseBody('v0.5.0')),
      });
      final checker = ReleaseChecker(env: env(), client: client);
      addTearDown(checker.close);

      await checker.checkCached();
      final cacheFile =
          File(p.join(home.path, '.tina', 'cache', 'latest_release.json'));
      expect(cacheFile.existsSync(), isTrue);
      final reread = ReleaseInfo.fromJson(
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>);
      expect(reread.tag, 'v0.5.0');
    });
  });

  test('ReleaseInfo toJson/fromJson round-trips', () {
    final info = ReleaseInfo(
      tag: 'v1.2.3',
      releaseUrl: 'https://example.com',
      assetUrls: const {'a.tar.gz': 'https://example.com/a.tar.gz'},
    );
    final copy = ReleaseInfo.fromJson(
        jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>);
    expect(copy.tag, 'v1.2.3');
    expect(copy.releaseUrl, 'https://example.com');
    expect(copy.assetUrls['a.tar.gz'], 'https://example.com/a.tar.gz');
  });
}
