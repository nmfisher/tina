import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../platform/paths.dart';
import 'models_dev_parse.dart';
import 'registry.dart';

final _log = Logger('tina.llm.models_dev.providers');

/// One models.dev provider entry, as published by
/// [models.dev](https://models.dev/api.json).
///
/// This is raw discovery data, not a [ProviderDescriptor]: turning it into a
/// descriptor needs a wire implementation, which lives in the composition
/// layer (`lib/composition/models_dev_seed.dart`) rather than here.
class ModelsDevProviderInfo {
  const ModelsDevProviderInfo({
    required this.key,
    required this.name,
    required this.envVars,
    required this.npm,
    required this.apiBase,
    required this.models,
  });

  /// The models.dev provider id (`nvidia`, `moonshotai`, …).
  final String key;

  /// Human-readable name ("Moonshot AI").
  final String name;

  /// Credential env var names, in models.dev priority order.
  final List<String> envVars;

  /// The AI SDK package that speaks this provider's wire format — the only
  /// signal models.dev gives about how to talk to it.
  final String npm;

  /// The provider's OpenAI-compatible base URL, when models.dev records one.
  final String? apiBase;

  /// Every model models.dev lists for this provider, keyed by id.
  final Map<String, ModelInfo> models;
}

/// Provider discovery feed backed by models.dev's `api.json`.
///
/// Deliberately separate from [ModelsDevCatalog]: that one overlays *model*
/// metadata from the curated `models.json` onto providers tina already knows,
/// while this one answers "which providers exist at all". The two feeds carry
/// different data — `models.json` is a small curated subset (378 entries
/// across 36 providers) whereas `api.json` lists all 213 providers with their
/// credentials, base URLs and full model sets — so repointing the overlay
/// would silently churn every compiled provider's picker.
///
/// Cache: `~/.tina/cache/models.dev.providers.json`, read by [loadFromCache]
/// **ignoring its age** (providers change far more slowly than models, and a
/// stale-but-present cache must still seed deterministically at startup), and
/// rewritten by [refresh]. Set `COCOON_MODELS_DEV=0` to skip both — enforced
/// by the caller, as with [ModelsDevCatalog].
class ModelsDevProviderCatalog {
  ModelsDevProviderCatalog({
    required Map<String, String> env,
    http.Client? client,
    Duration fetchTimeout = const Duration(seconds: 10),
  })  : _env = env,
        _client = client ?? http.Client(),
        _fetchTimeout = fetchTimeout;

  static const _endpoint = 'https://models.dev/api.json';

  final Map<String, String> _env;
  final http.Client _client;
  final Duration _fetchTimeout;

  final Map<String, ModelsDevProviderInfo> _providers = {};
  bool _cacheRead = false;
  bool _refreshing = false;
  DateTime? _cachedAt;
  String? _loadError;

  /// Every provider the last load/refresh saw, keyed by models.dev id.
  Map<String, ModelsDevProviderInfo> get providers =>
      Map.unmodifiable(_providers);

  /// When the cache this session seeded from was written, or null when no
  /// cache was present (first run) — the freshness indicator's input.
  DateTime? get cachedAt => _cachedAt;

  /// True while a refresh is in flight, or after one failed. The refresh's
  /// result only applies to the next launch, so a pending refresh is worth
  /// showing rather than hiding.
  bool get refreshPending => _refreshing || _loadError != null;

  /// Non-null when a refresh failed. Rendered by the settings panel.
  String? get loadWarning =>
      _loadError == null ? null : 'models.dev provider list unavailable '
          '($_loadError)';

  /// Seed from the on-disk cache. Idempotent; a missing or unreadable cache
  /// leaves [providers] empty (the refresh fills it for the next launch).
  Future<void> loadFromCache() async {
    if (_cacheRead) return;
    _cacheRead = true;
    final f = _cacheFile();
    if (!f.existsSync()) return;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return;
      _populate(raw);
      _cachedAt = f.statSync().modified;
    } catch (e) {
      _log.fine('models.dev providers cache parse failed; will refetch', e);
    }
  }

  /// Fetch `api.json`, parse it and rewrite the cache. Idempotent while one is
  /// in flight. Failures are logged at FINE and surfaced via [loadWarning];
  /// the providers already seeded from the cache stay in place.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final raw = await _fetch();
      if (raw == null) return;
      _populate(raw);
      _cachedAt = DateTime.now();
      _loadError = null;
      await _writeCache(_cacheFile(), raw);
    } finally {
      _refreshing = false;
    }
  }

  File _cacheFile() => File(
      p.join(tinaDirFromEnv(_env).path, 'cache', 'models.dev.providers.json'));

  Future<Map<String, dynamic>?> _fetch() async {
    try {
      final resp =
          await _client.get(Uri.parse(_endpoint)).timeout(_fetchTimeout);
      if (resp.statusCode != 200) {
        _loadError = 'HTTP ${resp.statusCode}';
        _log.fine('models.dev api.json returned ${resp.statusCode}');
        return null;
      }
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      _loadError = '$e';
      _log.fine('models.dev api.json fetch failed; seeded providers remain',
          e);
      return null;
    }
  }

  Future<void> _writeCache(File f, Map<String, dynamic> raw) async {
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(raw));
    } catch (e) {
      _log.fine('models.dev providers cache write failed', e);
    }
  }

  void _populate(Map<String, dynamic> raw) {
    _providers.clear();
    for (final entry in raw.entries) {
      final v = entry.value;
      if (v is! Map) continue;
      final p = v.cast<String, dynamic>();
      final api = (p['api'] as String?)?.trim();
      final models = <String, ModelInfo>{};
      final rawModels = p['models'];
      if (rawModels is Map) {
        for (final m in rawModels.entries) {
          final mv = m.value;
          if (mv is! Map) continue;
          final info = modelsDevModelInfo('${m.key}', mv.cast<String, dynamic>());
          if (info != null) models[info.id] = info;
        }
      }
      final env = p['env'];
      _providers[entry.key] = ModelsDevProviderInfo(
        key: entry.key,
        name: (p['name'] as String?) ?? entry.key,
        envVars: [
          if (env is List)
            for (final e in env)
              if (e is String && e.isNotEmpty) e,
        ],
        npm: (p['npm'] as String?) ?? '',
        apiBase: (api == null || api.isEmpty) ? null : api,
        models: models,
      );
    }
  }

  void close() => _client.close();
}
