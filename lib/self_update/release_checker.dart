import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'package:tina_engine/tina_engine.dart';

import '../version.g.dart';

final _log = Logger('tina.self_update');

/// The latest published release, as reported by the GitHub Releases API.
/// [assetUrls] maps asset name (`tina-v0.1.4-macos-arm64.tar.gz`) →
/// browser_download_url.
class ReleaseInfo {
  ReleaseInfo({required this.tag, required this.releaseUrl, required this.assetUrls});

  final String tag;
  final String releaseUrl;
  final Map<String, String> assetUrls;

  /// The version part of the tag, without the leading `v`.
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'release_url': releaseUrl,
        'assets': assetUrls,
      };

  static ReleaseInfo fromJson(Map<String, dynamic> json) => ReleaseInfo(
        tag: json['tag'] as String,
        releaseUrl: json['release_url'] as String? ?? '',
        assetUrls: (json['assets'] as Map?)?.cast<String, String>() ?? const {},
      );
}

/// Whether [tag] names a strictly newer release than the running [tinaVersion]
/// (or [current], in tests). Both are parsed as `v?MAJOR.MINOR.PATCH`;
/// anything unparsable compares false so a malformed tag can never trigger an
/// update prompt.
bool isNewer(String tag, {String? current}) {
  final cur = _parseSemver(current ?? tinaVersion);
  final next = _parseSemver(tag);
  if (cur == null || next == null) return false;
  for (var i = 0; i < 3; i++) {
    if (next[i] != cur[i]) return next[i] > cur[i];
  }
  return false;
}

int? _semverGroup(Match m, int i) => int.tryParse(m.group(i)!);

/// `v?MAJOR.MINOR.PATCH` → a comparable list. Null when it doesn't parse
/// (pre-release suffixes like `0.0.0-dev.3` are accepted and ignored).
List<int>? _parseSemver(String v) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(v.trim());
  if (m == null) return null;
  final major = _semverGroup(m, 1);
  final minor = _semverGroup(m, 2);
  final patch = _semverGroup(m, 3);
  if (major == null || minor == null || patch == null) return null;
  return [major, minor, patch];
}

/// Checks GitHub for the latest tina release, with a TTL cache under
/// `~/.tina/cache/` so the startup check doesn't hit the API every launch
/// (unauthenticated GitHub allows 60 req/hr). Modeled on [ModelsDevCatalog]:
/// injectable [http.Client], non-fatal failures logged at FINE.
class ReleaseChecker {
  ReleaseChecker({
    required Map<String, String> env,
    http.Client? client,
    this.apiBase = defaultApiBase,
    this.cacheTtl = const Duration(hours: 1),
    this.fetchTimeout = const Duration(seconds: 10),
  })  : _env = env,
        _client = client ?? http.Client();

  static const defaultApiBase = 'https://api.github.com/repos/nmfisher/tina';
  static const releasesPageUrl = 'https://github.com/nmfisher/tina/releases/latest';

  final Map<String, String> _env;
  final http.Client _client;
  final String apiBase;
  final Duration cacheTtl;
  final Duration fetchTimeout;

  bool _closed = false;

  /// Cache-first check: a fresh-enough `~/.tina/cache/latest_release.json`
  /// answers without the network; otherwise fetch and refresh the cache.
  /// Null on any failure (network, parse, IO) — the caller treats "unknown"
  /// as "no notice", never as an error.
  Future<ReleaseInfo?> checkCached() async {
    final cache = _cacheFile();
    final cached = await _readCache(cache);
    if (cached != null) return cached;
    final fresh = await fetchLatest();
    if (fresh != null) await _writeCache(cache, fresh);
    return fresh;
  }

  /// Always hit the network (`/update` uses this so an explicit ask never
  /// answers from a stale cache).
  Future<ReleaseInfo?> fetchLatest() async {
    try {
      final resp = await _client.get(
        Uri.parse('$apiBase/releases/latest'),
        headers: const {'Accept': 'application/vnd.github+json'},
      ).timeout(fetchTimeout);
      if (resp.statusCode != 200) {
        _log.fine('release check returned HTTP ${resp.statusCode}');
        return null;
      }
      return _parse(resp.body);
    } catch (e) {
      _log.fine('release check failed', e);
      return null;
    }
  }

  ReleaseInfo? _parse(String body) {
    try {
      final raw = jsonDecode(body) as Map<String, dynamic>;
      final tag = raw['tag_name'] as String?;
      if (tag == null || tag.isEmpty) return null;
      final assets = <String, String>{};
      for (final a in (raw['assets'] as List? ?? const [])) {
        if (a is! Map) continue;
        final name = a['name'];
        final url = a['browser_download_url'];
        if (name is String && url is String) assets[name] = url;
      }
      return ReleaseInfo(
        tag: tag,
        releaseUrl: (raw['html_url'] as String?) ?? releasesPageUrl,
        assetUrls: assets,
      );
    } catch (e) {
      _log.fine('release payload parse failed', e);
      return null;
    }
  }

  File _cacheFile() => File(p.join(tinaDirFromEnv(_env).path, 'cache', 'latest_release.json'));

  Future<ReleaseInfo?> _readCache(File f) async {
    try {
      if (!f.existsSync()) return null;
      final age = DateTime.now().difference(f.statSync().modified);
      if (age >= cacheTtl) return null;
      return ReleaseInfo.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (e) {
      _log.fine('release cache read failed; will refetch', e);
      return null;
    }
  }

  Future<void> _writeCache(File f, ReleaseInfo info) async {
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(info.toJson()));
    } catch (e) {
      _log.fine('release cache write failed', e);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}
