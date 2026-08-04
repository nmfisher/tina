import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../platform/paths.dart';
import 'model_catalog.dart';
import 'registry.dart';

final _log = Logger('tina.llm.models_dev');

/// Overlay catalog backed by [models.dev](https://models.dev/models.json).
///
/// Fetched once at startup, cached to `~/.tina/cache/models.dev.json`,
/// and layered on top of the compiled descriptor maps. Providers
/// models.dev doesn't know about (Tencent MaaS, local Ollama, etc.) keep
/// their hand-seeded maps as the source of truth — the overlay only adds,
/// it never removes.
///
/// `load()` is idempotent and non-fatal: a network miss leaves the
/// compiled maps intact. Set `COCOON_MODELS_DEV=0` to skip the fetch.
class ModelsDevCatalog implements ModelCatalog {
  ModelsDevCatalog({
    required Map<String, String> env,
    http.Client? client,
    Duration cacheTtl = const Duration(hours: 24),
    Duration fetchTimeout = const Duration(seconds: 10),
  })  : _env = env,
        _client = client ?? http.Client(),
        _ttl = cacheTtl,
        _fetchTimeout = fetchTimeout;

  static const _endpoint = 'https://models.dev/models.json';

  /// tina provider id → models.dev provider key. Models.dev names
  /// providers differently from us (alibaba vs qwen, zhipuai vs glm,
  /// xai vs grok, google vs gemini); this is the only mapping.
  static const _alias = <String, String>{
    'qwen': 'alibaba',
    'glm': 'zhipuai',
    'grok': 'xai',
    'gemini': 'google',
    'longcat': 'meituan',
  };

  final Map<String, String> _env;
  final http.Client _client;
  final Duration _ttl;
  final Duration _fetchTimeout;

  final Map<String, List<ModelInfo>> _byTinaId = {};
  bool _loaded = false;
  bool _attempted = false;
  String? _loadError;

  bool get isLoaded => _loaded;

  @override
  String? get loadWarning =>
      _loaded && _loadError != null ? 'Model catalog unavailable ($_loadError)' : null;

  /// Fetch + parse + cache. Idempotent: a re-call after success is a
  /// no-op. Failures (network, parse, IO) are logged at FINE and the
  /// compiled maps remain the source of truth.
  Future<void> load() async {
    if (_loaded || _attempted) return;
    _attempted = true;
    final cacheFile = _cacheFile();
    Map<String, dynamic>? raw = await _readCache(cacheFile);
    raw ??= await _fetch();
    if (raw != null) {
      _populate(raw);
      await _writeCache(cacheFile, raw);
    }
    _loaded = true;
  }

  File _cacheFile() {
    final dir = Directory(
        p.join(tinaDirFromEnv(_env).path, 'cache'));
    return File(p.join(dir.path, 'models.dev.json'));
  }

  Future<Map<String, dynamic>?> _readCache(File f) async {
    if (!f.existsSync()) return null;
    final age = DateTime.now().difference(f.statSync().modified);
    if (age >= _ttl) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      _log.fine('models.dev cache parse failed; will refetch', e);
      return null;
    }
  }

  Future<void> _writeCache(File f, Map<String, dynamic> raw) async {
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(raw));
    } catch (e) {
      _log.fine('models.dev cache write failed', e);
    }
  }

  Future<Map<String, dynamic>?> _fetch() async {
    try {
      final resp = await _client
          .get(Uri.parse(_endpoint))
          .timeout(_fetchTimeout);
      if (resp.statusCode != 200) {
        _loadError = 'HTTP ${resp.statusCode}';
        _log.fine('models.dev fetch returned ${resp.statusCode}');
        return null;
      }
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      _loadError = '$e';
      _log.fine('models.dev fetch failed; compiled maps remain authoritative',
          e);
      return null;
    }
  }

  void _populate(Map<String, dynamic> raw) {
    final byMdKey = <String, List<ModelInfo>>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final slash = key.indexOf('/');
      if (slash <= 0) continue;
      final mdProv = key.substring(0, slash);
      final modelId = key.substring(slash + 1);
      final v = entry.value;
      if (v is! Map) continue;
      final info = _toModelInfo(modelId, v.cast<String, dynamic>());
      if (info != null) {
        byMdKey.putIfAbsent(mdProv, () => []).add(info);
      }
    }
    // Reverse-alias into tina id space. An unaliased key (e.g. 'openai',
    // 'anthropic', 'tencent') passes through unchanged.
    for (final e in byMdKey.entries) {
      final tinaId = _reverseAlias(e.key) ?? e.key;
      _byTinaId[tinaId] = e.value;
    }
  }

  String? _reverseAlias(String mdKey) {
    for (final e in _alias.entries) {
      if (e.value == mdKey) return e.key;
    }
    return null;
  }

  ModelInfo? _toModelInfo(String modelId, Map<String, dynamic> m) {
    final limit = m['limit'];
    if (limit is! Map) return null;
    final context = (limit['context'] as num?)?.toInt();
    final output = (limit['output'] as num?)?.toInt();
    if (context == null || output == null) return null;
    final mods = m['modalities'];
    final inputs = (mods is Map
            ? (mods['input'] as List?)?.cast<String>()
            : null) ??
        const <String>[];
    return ModelInfo(
      id: modelId,
      name: (m['name'] as String?) ?? modelId,
      contextWindow: context,
      maxOutput: output,
      supportsTools: m['tool_call'] == true,
      supportsVision: inputs.contains('image'),
    );
  }

  @override
  List<ModelInfo> modelsFor(ProviderDescriptor desc) {
    final overlaid = _byTinaId[desc.id];
    if (overlaid != null && overlaid.isNotEmpty) return overlaid;
    return desc.models.values.toList();
  }

  @override
  ModelInfo? findModel(ProviderDescriptor desc, String modelId) {
    final overlaid = _byTinaId[desc.id];
    if (overlaid != null) {
      for (final m in overlaid) {
        if (m.id == modelId) return m;
      }
    }
    return desc.models[modelId];
  }

  @override
  bool hasAny(ProviderDescriptor desc) =>
      (_byTinaId[desc.id]?.isNotEmpty ?? false) || desc.models.isNotEmpty;

  void close() => _client.close();
}
