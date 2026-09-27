/// The models.dev catalogue: fetch once, cache on disk under tina's own
/// cache directory (`~/.tina/cache/models_dev/`), and read back for
/// model metadata — the same location and file names the old engine
/// uses, so there is one copy on disk rather than two.
///
/// The network sits behind the same injectable seam as the wires:
/// production passes an [HttpEndpoint] pointing at models.dev; tests
/// replay bytes and pass a temp directory. A failed or stale fetch is
/// never fatal — a turn falls back to the descriptor's own model list.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'descriptor.dart';
import 'http.dart';

/// The models.dev root the catalogue is fetched from.
const String modelsDevUrl = 'https://models.dev';

/// Where the catalogue is cached, relative to the tina directory: the
/// old engine's exact cache path, so both read one copy.
const String modelsDevCacheDir = 'cache/models_dev';

/// The cached file holding `{provider_id: {model_id: model_json}}`.
const String modelsDevCacheFile = 'models.json';

/// Fallback context window for catalogue entries without a `limit`
/// block. Generous rather than restrictive — a too-small window silently
/// truncates long contexts, while a too-large one only risks a visible
/// provider error.
const int modelsDevDefaultContextWindow = 131072;

/// One catalogue model, merged from the catalogue record and the
/// descriptor's own entry: catalogue limits and capability flags win
/// when present (fresher), descriptor values fill the gaps.
ModelInfo modelsDevModelInfo(String id, Map<String, dynamic> json,
    {ModelInfo? descriptor}) {
  final limit = json['limit'];
  final context = limit is Map ? (limit['context'] as num?)?.toInt() : null;
  final output = limit is Map ? (limit['output'] as num?)?.toInt() : null;
  final mods = json['modalities'];
  final inputs =
      (mods is Map ? (mods['input'] as List?)?.cast<String>() : null);
  return ModelInfo(
    id: id,
    name: (json['name'] as String?) ?? descriptor?.name ?? id,
    contextWindow: context ?? descriptor?.contextWindow ??
        modelsDevDefaultContextWindow,
    maxOutput: output != null && output > 0
        ? output
        : descriptor?.maxOutput,
    supportsTools: json['tool_call'] == true ||
        (descriptor?.supportsTools ?? false),
    supportsVision: inputs?.contains('image') ??
        descriptor?.supportsVision ??
        false,
  );
}

/// The catalogue as fetched and cached: provider id → model id → raw
/// record. Parse lazily, merge with the descriptors at read time.
class ModelsDevCatalog {
  ModelsDevCatalog._(this._providers, this.cachePath);

  final Map<String, Map<String, dynamic>> _providers;

  /// Where the copy on disk lives, for diagnostics.
  final String cachePath;

  /// Fetch from [endpoint] (a GET on the models.dev API path — the seam
  /// is POST-shaped for the wires, so the catalogue carries its own
  /// fetch), cache to [cacheDir] (default tina's own), and return the
  /// parsed catalogue. Any failure returns null and touches nothing:
  /// absence of the catalogue is a fallback, not an error.
  static Future<ModelsDevCatalog?> fetch({
    required HttpEndpoint endpoint,
    required String Function() tokenFrom,
    String? cacheDir,
  }) async {
    final dir = cacheDir ?? _defaultCacheDir();
    try {
      final response = await endpoint.get(
        '/api.json',
        headers: {'accept': 'application/json'},
      );
      if (response.statusCode != 200) return null;
      final body = await response.body
          .transform(utf8.decoder)
          .fold(StringBuffer(), (b, c) => b..write(c))
          .then((b) => b.toString());
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final providers = <String, Map<String, dynamic>>{};
      decoded.forEach((id, value) {
        if (value is Map<String, dynamic> && value['models'] is Map) {
          providers[id] = value;
        }
      });
      if (providers.isEmpty) return null;
      final file = File('$dir/$modelsDevCacheFile');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(providers),
        flush: true,
      );
      return ModelsDevCatalog._(providers, file.path);
    } catch (_) {
      // No catalogue: descriptors carry the turn. Never fatal.
      return null;
    }
  }

  /// Read the last fetched copy from [cacheDir] (default tina's own), or
  /// null when it was never fetched. Staleness is the caller's call —
  /// the merge tolerates whatever age this has.
  static Future<ModelsDevCatalog?> read({String? cacheDir}) async {
    final dir = cacheDir ?? _defaultCacheDir();
    try {
      final text = await File('$dir/$modelsDevCacheFile').readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final providers = <String, Map<String, dynamic>>{};
      decoded.forEach((id, value) {
        if (value is Map<String, dynamic>) providers[id] = value;
      });
      if (providers.isEmpty) return null;
      return ModelsDevCatalog._(providers, '$dir/$modelsDevCacheFile');
    } catch (_) {
      return null;
    }
  }

  /// True when the cached copy is older than [maxAge]. A missing copy is
  /// stale by definition; an unreadable stamp is treated as stale so a
  /// refetch is attempted rather than trusted.
  bool isStale(Duration maxAge) {
    try {
      final stamp = File('$cachePath.stamp').lastModifiedSync();
      return DateTime.now().difference(stamp) > maxAge;
    } catch (_) {
      return true;
    }
  }

  /// The merged model list for a descriptor: catalogue records where the
  /// catalogue knows the provider, descriptor entries merged in and
  /// always present. Order: descriptor order first, then catalogue-only
  /// ids alphabetically — stable for display.
  List<ModelInfo> modelsFor(ProviderDescriptor descriptor) {
    final catalogue = _providers[descriptor.id]?['models'];
    final records =
        catalogue is Map<String, dynamic> ? catalogue : const <String, dynamic>{};
    final merged = <String, ModelInfo>{};
    for (final m in descriptor.models.values) {
      final record = records[m.id];
      merged[m.id] = record is Map<String, dynamic>
          ? modelsDevModelInfo(m.id, record, descriptor: m)
          : m;
    }
    final extraIds = records.keys
        .where((id) => !merged.containsKey(id))
        .toList()
      ..sort();
    for (final id in extraIds) {
      final record = records[id];
      if (record is Map<String, dynamic>) {
        merged[id] = modelsDevModelInfo(id, record);
      }
    }
    return merged.values.toList(growable: false);
  }
}

/// `$HOME/.tina` (or `%USERPROFILE%`), falling back to the current
/// directory — the same resolution tina uses everywhere else.
String _defaultCacheDir() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
  return '$home/.tina/$modelsDevCacheDir';
}
