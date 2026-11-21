import 'dart:convert';

import 'package:toml/toml.dart' as toml;

import 'package:tina/src/app_io.dart';
import 'package:tina/src/config_document.dart' show ConfigDocument;
import 'package:tina/src/settings_catalog.dart' show mergeSettingLayers;
import 'package:tina/src/settings_surface.dart'
    show CatalogSettingsBackend, ConfigSettingsSurface;
import 'package:tina/src/settings_stack.dart' show GlobalDocumentSource;
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/portable_tools.dart'
    show CommandApprovalScope, ToolCommandApprovals;

String wasmProviderEndpoint(
  Map<String, dynamic> globalConfig,
  Map<String, String> environment,
) {
  final explicit = environment['TINA_LLM_ENDPOINT']?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final defaults = globalConfig['default'];
  final providers = globalConfig['providers'];
  final model = defaults is Map ? defaults['model'] : null;
  final provider = (defaults is Map ? defaults['provider'] as String? : null) ??
      (model is String && model.contains('/') ? model.split('/').first : null) ??
      (providers is Map && providers.length == 1 ? providers.keys.single as String : 'anthropic');
  final configured = providers is Map ? providers[provider] : null;
  final baseUrl = configured is Map ? configured['base_url'] : null;
  if (baseUrl is String && baseUrl.trim().isNotEmpty) return baseUrl.trim();
  if (provider == 'anthropic') return 'https://api.anthropic.com';
  throw StateError('Set base_url for Wasm provider $provider or supply TINA_LLM_ENDPOINT');
}

/// The preloaded settings backend: global and workspace documents from
/// the snapshot, an in-memory session layer, and the shared merge.
final class PreloadedSettingsBackend
    implements
        SettingsBackend,
        GlobalDocumentSource,
        ConfigSettingsSurface,
        CatalogSettingsBackend {
  PreloadedSettingsBackend(
    this._io, {
    required this.globalPath,
    required this.workspacePath,
  });

  final AppIo _io;
  final String globalPath;
  final String workspacePath;

  @override
  bool get persistsConfiguration => false;

  final Map<String, Object?> _session = {};
  SettingCatalog? _catalog;

  @override
  void bindCatalog(SettingCatalog catalog) => _catalog = catalog;

  Iterable<SettingDefinition<Object>> _definitions(SettingScope scope) =>
      (_catalog?.definitions ?? const <SettingDefinition<Object>>[]).where(
        (definition) =>
            definition.scopes.contains(scope) &&
            (scope != SettingScope.workspace ||
                !_privateSettings.contains(definition.id)),
      );

  static const _privateSettings = {
    'tina/mode/classifier_instruction',
    'tina/tools/read_only_directories',
    'tina/tools/write_directories',
    'tina/tools/allow_reads_outside_workspace',
    'tina/tools/home_caches',
  };

  String? _raw(String path) => _io.readTextIfExists(path);

  @override
  Map<String, Object?> read(SettingScope scope) => scope == SettingScope.session
      ? Map.of(_session)
      : _readSettings(document(scope), scope);

  Map<String, Object?> _readSettings(
    Map<String, dynamic> document,
    SettingScope scope,
  ) => {
    for (final definition in _definitions(scope))
      if (_readValue(document, definition) case final Object value)
        definition.id: value,
  };

  Object? _readValue(
    Map<String, dynamic> document,
    SettingDefinition<Object> definition,
  ) {
    if (definition.readConfig?.call(document) case final Object value)
      return value;
    Object? value = document;
    for (final key in definition.configPath) {
      if (value is! Map) return null;
      value = value[key];
    }
    return value;
  }

  @override
  void write(SettingScope scope, Map<String, Object?> values) {
    if (scope == SettingScope.session) {
      _session
        ..clear()
        ..addAll(values);
      return;
    }
    if (scope == SettingScope.workspace && _sameFile) {
      throw StateError('Global and workspace config refer to the same file');
    }
    final output = document(scope);
    for (final definition in _definitions(scope)) {
      _writeValue(output, definition, values[definition.id]);
    }
    final path = scope == SettingScope.global ? globalPath : workspacePath;
    _io.writeText(path, toml.TomlDocument.fromMap(output).toString());
  }

  void _writeValue(
    Map<String, dynamic> document,
    SettingDefinition<Object> definition,
    Object? value,
  ) {
    if (definition.writeConfig case final write?) {
      write(document, value);
      return;
    }
    var table = document;
    for (final key in definition.configPath.take(
      definition.configPath.length - 1,
    )) {
      if (!table.containsKey(key) && value == null) return;
      table = table.putIfAbsent(
        key,
        () => <String, dynamic>{},
      ) as Map<String, dynamic>;
    }
    final key = definition.configPath.last;
    if (value == null) {
      table.remove(key);
    } else {
      table[key] = value;
    }
  }

  bool get _sameFile => globalPath == workspacePath;

  Map<String, dynamic> _parse(String path) {
    final raw = _raw(path);
    if (raw == null) return <String, Object?>{};
    try {
      return toml.TomlDocument.parse(raw).toMap();
    } catch (_) {
      return <String, Object?>{};
    }
  }

  @override
  Map<String, dynamic> globalDocument() =>
      Map<String, dynamic>.from(_parse(globalPath));

  // ---- ConfigSettingsSurface ------------------------------------------------
  //
  // The preloaded backend is session-only: nothing touches the host
  // beyond the snapshot (the stage-5 contract), so the surface members
  // answer from memory — the permission store is empty, plugin toggles
  // land in the session layer, and documents/drafts view the snapshot.

  @override
  ToolCommandApprovals get permissionStore => const _NoCommandApprovals();

  @override
  void setPluginInAllScopes(
    ScopedSettings settings,
    SettingDefinition<Object> definition,
    bool? enabled, {
    bool refresh = true,
  }) {
    if (!definition.id.endsWith('/enabled') ||
        definition.configPath.first != 'plugins') {
      throw ArgumentError('All scopes is only available for plugin toggles');
    }
    if (_sameFile)
      throw StateError('Global and workspace config refer to the same file');
    for (final scope in definition.scopes) {
      final values = read(scope);
      if (enabled == null) {
        values.remove(definition.id);
      } else {
        values[definition.id] = enabled;
      }
      write(scope, values);
    }
    if (refresh) settings.reload();
  }

  @override
  Map<String, dynamic> effectiveDocument({
    Map<SettingScope, Map<String, Object?>>? layers,
  }) => mergeSettingLayers(
    globalDocument: globalDocument(),
    layers:
        layers ?? {for (final scope in SettingScope.values) scope: read(scope)},
    definitions: _catalog?.definitions ?? const [],
  );

  @override
  Map<String, dynamic> document(SettingScope scope) => switch (scope) {
    SettingScope.session => {},
    SettingScope.global => _parse(globalPath),
    SettingScope.workspace => _sameFile ? {} : _parse(workspacePath),
  };

  @override
  ConfigDocument draft(
    ScopedSettings settings,
    SettingScope scope, {
    void Function(Map<String, Object?>, Set<String>)? commit,
  }) {
    final initial = effectiveDocument(
      layers: {
        for (final layer in SettingScope.values)
          layer: layer.index < scope.index ? {} : read(layer),
      },
    );
    final before = _readSettings(initial, scope);
    final copy = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(initial)) as Map,
    );
    return ConfigDocument.draft(copy, (modified) {
      final after = _readSettings(modified, scope);
      final updates = {
        for (final entry in after.entries)
          if (jsonEncode(entry.value) != jsonEncode(before[entry.key]))
            entry.key: entry.value,
      };
      final removed = before.keys.toSet().difference(after.keys.toSet());
      if (updates.isEmpty && removed.isEmpty) return;
      if (commit != null) {
        commit(updates, removed);
      } else {
        settings.update(scope, updates, remove: removed);
      }
    });
  }
}

/// The preloaded backend's permission store: nothing is remembered, and
/// nothing can be (approvals under wasm are session answers, not files).
final class _NoCommandApprovals implements ToolCommandApprovals {
  const _NoCommandApprovals();

  @override
  List<Map<String, Object?>> get entries => const [];

  @override
  bool coversAccess(String capability, String target) => false;

  @override
  void revoke(String id, {String? directory}) {}

  @override
  Map<String, Object?> settings(CommandApprovalScope scope) => const {};

  @override
  String? get filePath => null;
}
