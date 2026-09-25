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
  ReleaseInfo({
    required this.tag,
    required this.releaseUrl,
    required this.assetUrls,
  });

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

/// Why a release fetch failed. Not an exception — a miss is a normal,
/// non-fatal outcome ("unknown", never an error) — but it is no longer
/// invisible: [ReleaseChecker.lastMiss] carries the most recent one so
/// callers can say *why* no update notice appeared, instead of leaving
/// "check failed" to read as "up to date".
class ReleaseMiss {
  const ReleaseMiss.http(this.status, {this.retryAt})
    : kind = MissKind.http,
      detail = 'HTTP $status';
  const ReleaseMiss.network(this.detail)
    : kind = MissKind.network,
      status = null,
      retryAt = null;
  const ReleaseMiss.badPayload()
    : kind = MissKind.badPayload,
      status = null,
      detail = 'unparsable release payload',
      retryAt = null;

  final MissKind kind;

  /// HTTP status for [MissKind.http], null otherwise.
  final int? status;
  final String detail;

  /// When the server says asking again is acceptable — from `retry-after`
  /// or `x-ratelimit-reset` — or null when it said nothing (the checker
  /// then applies its own default backoff window).
  final DateTime? retryAt;

  /// GitHub's unauthenticated budget is 60 req/hr per IP, and a 403 is the
  /// shape rate limiting takes here — common on shared egress addresses.
  bool get rateLimited => kind == MissKind.http && status == 403;

  @override
  String toString() => detail;
}

enum MissKind { network, http, badPayload }

/// Checks GitHub for the latest tina release, with a TTL cache under
/// `~/.tina/cache/` so the startup check doesn't hit the API every launch
/// (unauthenticated GitHub allows 60 req/hr). Modeled on [ModelsDevCatalog]:
/// injectable [http.Client], non-fatal failures logged at INFO with the
/// reason (and mirrored on [ReleaseChecker.lastMiss]); a miss still returns
/// null, never throws.
class ReleaseChecker {
  ReleaseChecker({
    required Map<String, String> env,
    http.Client? client,
    this.apiBase = defaultApiBase,
    this.cacheTtl = const Duration(hours: 1),
    this.fetchTimeout = const Duration(seconds: 10),
    this.deferWhile = defaultDeferWhile,
    this.respectServerRetryAt = true,
  }) : _env = env,
       _client = client ?? http.Client();

  static const defaultApiBase = 'https://api.github.com/repos/nmfisher/tina';
  static const releasesPageUrl =
      'https://github.com/nmfisher/tina/releases/latest';

  /// Background probes defer while a recorded defer window is open. The
  /// window comes from the server when it says one (`retry-after`,
  /// `x-ratelimit-reset`), else these defaults by failure shape.
  static const defaultDeferWhile = Duration(hours: 1);
  static const defaultRateLimitBackoff = Duration(minutes: 10);
  static const defaultServerErrorBackoff = Duration(minutes: 5);
  static const defaultHttpBackoff = Duration(minutes: 2);

  /// Connection-level failures say nothing about retry timing; a short
  /// window keeps flaky-network blips from silencing the check without
  /// hammering through an outage.
  static const defaultNetworkBackoff = Duration(minutes: 1);

  /// A far-future `retry-after`/`x-ratelimit-reset` is capped here so a
  /// bogus header cannot silence the check for days. Past this, background
  /// checks return to a normal cadence with their usual visibility.
  static const maxBackoff = Duration(hours: 2);

  final Map<String, String> _env;
  final http.Client _client;
  final String apiBase;
  final Duration cacheTtl;
  final Duration fetchTimeout;

  /// How long background checks defer once a defer window is recorded.
  final Duration deferWhile;

  /// Test seam: pretend the server said nothing even when it did, so the
  /// default windows are exercisable without a wall clock.
  final bool respectServerRetryAt;

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

  /// Cache-first with revalidation. A cached answer still wins immediately
  /// when it already names a newer release, but a cached "not newer" is only
  /// as fresh as the cache: a release published inside the cache's TTL window
  /// would otherwise stay invisible for up to [cacheTtl] (0.8.31 shipped
  /// during exactly such a window, so 0.8.30 sat silent). A cached miss
  /// therefore falls through to one live probe; if the network also misses,
  /// the cached value is returned — it remains the best-known answer and an
  /// explicit `/update` always re-probes anyway. Null only when neither the
  /// cache nor the network knows.
  ///
  /// Background-only backoff: while a defer window is open (set by a
  /// previous failed fetch — see [deferUntil]), the probe is skipped and
  /// the cached answer (possibly null) returns unchanged; nothing logs and
  /// no notice is minted, so a deferral is quiet. An explicit `/update`
  /// bypasses the gate by calling [fetchLatest] directly.
  Future<ReleaseInfo?> checkWithRevalidate() async {
    final cache = _cacheFile();
    final cached = await _readCache(cache);
    if (cached != null && isNewer(cached.tag)) return cached;
    if (deferUntil != null) {
      _log.fine('release check deferred until $deferUntil');
      return cached;
    }
    final fresh = await fetchLatest();
    if (fresh != null) {
      await _writeCache(cache, fresh);
      return fresh;
    }
    return cached;
  }

  /// Always hit the network (`/update` uses this so an explicit ask never
  /// answers from a stale cache, and is never deferred). Null on failure;
  /// the reason is on [lastMiss] and in the log at INFO (a miss is a normal
  /// outcome, but it must not read as "up to date"). A miss also persists a
  /// defer window (server guidance from `retry-after`/`x-ratelimit-reset`
  /// when offered, a short default otherwise) so subsequent *background*
  /// checks back off instead of burning the shared 60 req/hr budget;
  /// a success clears it.
  Future<ReleaseInfo?> fetchLatest() async {
    try {
      final resp = await _client
          .get(
            Uri.parse('$apiBase/releases/latest'),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(fetchTimeout);
      final status = resp.statusCode;
      if (status != 200) {
        final retryAt = respectServerRetryAt ? _retryAt(resp.headers) : null;
        _lastMiss = ReleaseMiss.http(status, retryAt: retryAt);
        await _setBackoff(
          DateTime.now().add(_deferWindow(status, retryAt)),
          _lastMiss!.detail,
        );
        _log.info(
          'release check missed: $_lastMiss'
          '${status == 403 ? ' (likely rate-limited)' : ''}; '
          'background probes deferred',
        );
        return null;
      }
      final parsed = _parse(resp.body);
      if (parsed == null) {
        await _setBackoff(
          DateTime.now().add(defaultHttpBackoff),
          _lastMiss!.detail,
        );
      } else {
        await _setBackoff(null, null);
      }
      return parsed;
    } catch (e) {
      _lastMiss = ReleaseMiss.network('$e'.isEmpty ? 'network error' : '$e');
      await _setBackoff(
        DateTime.now().add(defaultNetworkBackoff),
        _lastMiss!.detail,
      );
      _log.info('release check missed: $_lastMiss; background probes deferred');
      return null;
    }
  }

  /// Header-driven retry time for a failed response: `retry-after` (delay
  /// seconds or HTTP-date) wins, then GitHub's `x-ratelimit-reset` (UTC
  /// epoch seconds). Null when the server said nothing.
  DateTime? _retryAt(Map<String, String> headers) {
    final retryAfter = headers['retry-after']?.trim();
    if (retryAfter != null && retryAfter.isNotEmpty) {
      final seconds = int.tryParse(retryAfter);
      if (seconds != null) {
        return DateTime.now().add(
          Duration(seconds: seconds.clamp(0, maxBackoff.inSeconds)),
        );
      }
      try {
        return HttpDate.parse(retryAfter);
      } catch (_) {
        // Not a date either — fall through to the rate-limit header.
      }
    }
    final reset = int.tryParse((headers['x-ratelimit-reset'] ?? '').trim());
    if (reset != null) {
      return DateTime.fromMillisecondsSinceEpoch(reset * 1000);
    }
    return null;
  }

  /// How long to defer background probes after a failed response with
  /// [status]. Server guidance is honored but capped at [maxBackoff] so a
  /// bogus far-future reset cannot silence the check for days; with no
  /// guidance the window depends on the failure shape (a 403 is the shared
  /// rate-limit budget, a 5xx is GitHub's trouble, anything else is likely
  /// a persistent config problem and waits longest).
  Duration _deferWindow(int status, DateTime? retryAt) {
    final now = DateTime.now();
    if (retryAt != null && retryAt.isAfter(now)) {
      return retryAt.isBefore(now.add(maxBackoff))
          ? retryAt.difference(now)
          : maxBackoff;
    }
    return switch (status) {
      403 => defaultRateLimitBackoff,
      >= 500 => defaultServerErrorBackoff,
      _ => defaultHttpBackoff,
    };
  }

  /// Why the most recent [fetchLatest] failed, or null when it succeeded.
  /// A "stale answer" signal for callers: after a check that ends with this
  /// set, any notice already on screen may be out of date and the best-known
  /// answer comes from the cache.
  ReleaseMiss? _lastMiss;
  ReleaseMiss? get lastMiss => _lastMiss;

  /// Background probes defer until this instant, persisted under the tina
  /// cache dir so a defer window survives restarts (the point is to stop
  /// *the next launch* from re-probing into a rate limit). Null when no
  /// window is open.
  DateTime? get deferUntil => _readDeferUntil();

  File _deferFile() =>
      File(p.join(tinaDirFromEnv(_env).path, 'cache', 'release_check.defer'));

  DateTime? _readDeferUntil() {
    try {
      final raw = _deferFile().readAsStringSync().trim();
      if (raw.isEmpty) return null;
      final epochMs = int.parse(raw);
      final until = DateTime.fromMillisecondsSinceEpoch(epochMs);
      return until.isAfter(DateTime.now()) ? until : null;
    } catch (_) {
      return null; // Absent, stale, or unreadable — no window open.
    }
  }

  /// Records or clears the defer window. Best-effort like the release
  /// cache: an unwritable cache dir simply loses the window (and the next
  /// launch re-probes into the miss once — visible, and cheap).
  Future<void> _setBackoff(DateTime? until, String? reason) async {
    try {
      final f = _deferFile();
      if (until == null) {
        if (f.existsSync()) await f.delete();
      } else {
        await f.parent.create(recursive: true);
        await f.writeAsString(until.millisecondsSinceEpoch.toString());
        if (reason != null) {
          _log.info(
            'background release checks deferred until $until ($reason)',
          );
        }
      }
    } catch (e) {
      _log.fine('release defer write failed', e);
    }
  }

  /// Forces a defer window until [until] (test hook; also the seam for a
  /// future operator override). Persists like an automatic window.
  Future<void> deferUntilForTest(DateTime until) =>
      _setBackoff(until, 'forced by test');

  ReleaseInfo? _parse(String body) {
    try {
      final raw = jsonDecode(body) as Map<String, dynamic>;
      final tag = raw['tag_name'] as String?;
      if (tag == null || tag.isEmpty) {
        _lastMiss = const ReleaseMiss.badPayload();
        return null;
      }
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
      _lastMiss = const ReleaseMiss.badPayload();
      _log.fine('release payload parse failed', e);
      return null;
    }
  }

  File _cacheFile() =>
      File(p.join(tinaDirFromEnv(_env).path, 'cache', 'latest_release.json'));

  Future<ReleaseInfo?> _readCache(File f) async {
    try {
      if (!f.existsSync()) return null;
      final age = DateTime.now().difference(f.statSync().modified);
      if (age >= cacheTtl) return null;
      return ReleaseInfo.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>,
      );
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
