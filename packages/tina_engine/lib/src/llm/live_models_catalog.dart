import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../platform/paths.dart';
import 'model_catalog.dart';
import 'registry.dart';

final _log = Logger('tina.llm.liveModels');

/// Overlay catalog that lists each provider's actually-servable models from
/// its OpenAI-compatible `GET /v1/models` endpoint, using the user's own key.
///
/// Providers rotate their catalogs faster than the compiled descriptor maps
/// (or models.dev) can track — NIM especially. This catalog fetches the
/// authoritative id list at startup, caches it to
/// `~/.tina/cache/provider_models/<id>.json` (24h TTL), and layers it over
/// [inner] (typically [ModelsDevCatalog]) and the compiled map:
///
/// * the live id list is the catalog — a model the provider no longer serves
///   disappears, a brand-new one appears with the exact serve id;
/// * metadata (context window, max output, tool/vision support, extraBody)
///   comes from [inner] or the compiled map when the id is known there, and
///   from documented placeholder defaults otherwise — `/v1/models` returns
///   ids only;
/// * providers without live data (fetch failed, no key, not
///   [ProviderDescriptor.listsRemoteModels]) fall through to [inner]/compiled
///   unchanged.
///
/// Non-chat entries the endpoint still lists (embedders, rerankers, safety
/// classifiers) are filtered out — they can't serve `/chat/completions`.
///
/// `load()` is idempotent and non-fatal: any per-provider failure (network,
/// auth, parse) is logged at FINE and that provider simply keeps its
/// compiled/inner list. Auth resolution mirrors the registry: the first of
/// the descriptor's [AuthSource] env vars that is set supplies the key, and
/// the base URL is `<PREFIX>_BASE_URL` (prefix derived from the auth env var
/// or the provider id, matching how user config exports overrides) falling
/// back to [ProviderDescriptor.defaultBaseUrl].
class LiveModelsCatalog implements ModelCatalog {
  LiveModelsCatalog({
    required Map<String, String> env,
    ModelCatalog? inner,
    http.Client? client,
    Duration cacheTtl = const Duration(hours: 24),
    Duration fetchTimeout = const Duration(seconds: 10),
  })  : _env = env,
        _inner = inner,
        _client = client ?? http.Client(),
        _ttl = cacheTtl,
        _fetchTimeout = fetchTimeout;

  final Map<String, String> _env;
  final ModelCatalog? _inner;
  final http.Client _client;
  final Duration _ttl;
  final Duration _fetchTimeout;

  /// Placeholder metadata for live ids neither [inner] nor the compiled map
  /// knows: `/v1/models` returns ids only. Generous rather than restrictive —
  /// a too-small window would silently truncate long contexts, while a too-
  /// large one only risks a provider-side error the user can see and correct.
  static const _defaultContextWindow = 131072;
  static const _defaultMaxOutput = 8192;

  /// Live model-id lists per provider id, in endpoint order. A provider is
  /// here only after a successful fetch/cache read.
  final Map<String, List<String>> _liveIds = {};

  /// First per-provider failure, surfaced (once) via [loadWarning].
  String? _loadError;

  bool _attempted = false;

  @override
  String? get loadWarning =>
      _inner?.loadWarning ?? (_loadError == null ? null : '$_loadError');

  /// Fetch/cache the model lists for every [descriptors] entry that opts in
  /// ([ProviderDescriptor.listsRemoteModels]) and has credentials. One
  /// provider's failure never blocks the others.
  Future<void> load(Iterable<ProviderDescriptor> descriptors) async {
    if (_attempted) return;
    _attempted = true;
    await Future.wait([
      for (final desc in descriptors)
        if (desc.listsRemoteModels) _loadOne(desc),
    ]);
  }

  Future<void> _loadOne(ProviderDescriptor desc) async {
    if (!_authKey(desc).isNotEmpty && _env[_baseUrlVar(desc)] == null) {
      // No credentials: an anonymous /v1/models hit would 401. Keep the
      // compiled/inner list.
      return;
    }
    final ids = await _cachedIds(desc) ?? await _fetchIds(desc);
    if (ids != null) _liveIds[desc.id] = ids;
  }

  // -- Resolution ----------------------------------------------------------

  String _authKey(ProviderDescriptor desc) {
    for (final src in desc.authSources) {
      final v = _env[src.envVar];
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  String _baseUrlVar(ProviderDescriptor desc) => '${_prefix(desc)}_BASE_URL';

  String _prefix(ProviderDescriptor desc) {
    // The user config exports overrides as <PREFIX>_BASE_URL where PREFIX is
    // the auth env var's own prefix (e.g. NVIDIA_API_KEY → NVIDIA_BASE_URL),
    // falling back to the uppercased provider id.
    final first = desc.authSources.isEmpty ? null : desc.authSources.first;
    if (first != null && first.envVar.endsWith('_API_KEY')) {
      return first.envVar.substring(0, first.envVar.length - '_API_KEY'.length);
    }
    return desc.id.toUpperCase();
  }

  Uri _modelsUri(ProviderDescriptor desc) {
    final base =
        _env[_baseUrlVar(desc)] ?? desc.defaultBaseUrl;
    return Uri.parse('$base/v1/models');
  }

  // -- Cache ---------------------------------------------------------------

  File _cacheFile(ProviderDescriptor desc) {
    final dir = Directory(
        p.join(tinaDirFromEnv(_env).path, 'cache', 'provider_models'));
    return File(p.join(dir.path, '${desc.id}.json'));
  }

  Future<List<String>?> _cachedIds(ProviderDescriptor desc) async {
    final f = _cacheFile(desc);
    if (!f.existsSync()) return null;
    final age = DateTime.now().difference(f.statSync().modified);
    if (age >= _ttl) return null;
    try {
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final models = raw['models'];
      if (models is! List) return null;
      return models.whereType<String>().toList();
    } catch (e) {
      _log.fine('${desc.id} live-models cache parse failed', e);
      return null;
    }
  }

  Future<void> _writeCache(ProviderDescriptor desc, List<String> ids) async {
    try {
      final f = _cacheFile(desc);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'fetchedAt': DateTime.now().toIso8601String(),
        'models': ids,
      }));
    } catch (e) {
      _log.fine('${desc.id} live-models cache write failed', e);
    }
  }

  // -- Fetch ---------------------------------------------------------------

  Future<List<String>?> _fetchIds(ProviderDescriptor desc) async {
    try {
      final req = http.Request('GET', _modelsUri(desc));
      final key = _authKey(desc);
      if (key.isNotEmpty) req.headers['Authorization'] = 'Bearer $key';
      final resp = await _client.send(req).timeout(_fetchTimeout);
      final body = await resp.stream.bytesToString();
      if (resp.statusCode != 200) {
        _noteError('${desc.id}: HTTP ${resp.statusCode}');
        return null;
      }
      final decoded = jsonDecode(body);
      // OpenAI shape: {"data":[{"id":"..."},...]}. Tolerate a bare list too.
      final List data;
      if (decoded is Map<String, dynamic> && decoded['data'] is List) {
        data = decoded['data'] as List;
      } else if (decoded is List) {
        data = decoded;
      } else {
        _noteError('${desc.id}: unexpected /v1/models shape');
        return null;
      }
      final ids = data
          .whereType<Map>()
          .map((m) => m['id'])
          .whereType<String>()
          .where(_isChatModel)
          .toList(growable: false);
      await _writeCache(desc, ids);
      return ids;
    } catch (e) {
      _noteError('${desc.id}: $e');
      _log.fine('${desc.id} /v1/models fetch failed; keeping compiled list',
          e);
      return null;
    }
  }

  void _noteError(String message) {
    _loadError ??= message;
  }

  /// Non-chat models the endpoint still lists. Substring heuristics on the
  /// id — NIM serves `nv-embedqa-*`, `rerank-*`, and `*-content-safety-*`
  /// families behind the same endpoint, none of which answer completions.
  static bool _isChatModel(String id) {
    final lower = id.toLowerCase();
    return !lower.contains('embed') &&
        !lower.contains('rerank') &&
        !lower.contains('content-safety') &&
        !lower.contains('guard');
  }

  // -- ModelCatalog --------------------------------------------------------

  List<ModelInfo> _resolveAll(ProviderDescriptor desc) =>
      _inner?.modelsFor(desc) ?? desc.models.values.toList();

  @override
  List<ModelInfo> modelsFor(ProviderDescriptor desc) {
    final live = _liveIds[desc.id];
    if (live == null) return _resolveAll(desc);
    return [for (final id in live) _resolveOne(desc, id)];
  }

  ModelInfo _resolveOne(ProviderDescriptor desc, String id) =>
      _inner?.findModel(desc, id) ??
      desc.models[id] ??
      ModelInfo(
        id: id,
        name: id,
        contextWindow: _defaultContextWindow,
        maxOutput: _defaultMaxOutput,
      );

  @override
  ModelInfo? findModel(ProviderDescriptor desc, String modelId) {
    final live = _liveIds[desc.id];
    if (live != null && !live.contains(modelId)) return null;
    return _resolveOne(desc, modelId);
  }

  @override
  bool hasAny(ProviderDescriptor desc) =>
      (_liveIds[desc.id]?.isNotEmpty ?? false) || _resolveAll(desc).isNotEmpty;

  @override
  void close() {
    _inner?.close();
    _client.close();
  }
}
