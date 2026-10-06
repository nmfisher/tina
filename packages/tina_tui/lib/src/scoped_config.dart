import 'dart:convert';
import 'dart:io';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_llm/tina_llm.dart';
import 'assembly_config.dart';
import 'config_document.dart';

Map<String, dynamic> _copy(Map<String, dynamic> values) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(values)) as Map);

Object? _at(Map<String, dynamic> values, List<String> path) {
  Object? value = values;
  for (final part in path) {
    value = value is Map ? value[part] : null;
  }
  return value;
}

void _put(Map<String, dynamic> values, List<String> path, Object? value) {
  var parent = values;
  for (final part in path.take(path.length - 1)) {
    if (value == null && !parent.containsKey(part)) return;
    parent = parent.putIfAbsent(part, () => <String, dynamic>{})
        as Map<String, dynamic>;
  }
  if (value == null) {
    parent.remove(path.last);
  } else {
    parent[path.last] = value;
  }
}

/// Filesystem adapter. Inheritance and validation remain in tina_settings.
final class ConfigSettingsBackend implements SettingsBackend {
  ConfigSettingsBackend(
      {required this.catalog,
      required this.globalPath,
      required this.workspacePath,
      required this.descriptors,
      this.validateSelection,
      this.onChanged});
  final SettingCatalog catalog;
  final String globalPath, workspacePath;
  final List<ProviderDescriptor> descriptors;
  final void Function(Map<String, dynamic>)? validateSelection;
  final void Function()? onChanged;
  Map<String, Object?> _session = {};
  final _snapshots = <SettingScope, ConfigDocument>{};

  bool get sameFile {
    String canonical(String value) => File(value).existsSync()
        ? File(value).resolveSymbolicLinksSync()
        : File(value).absolute.path;
    return canonical(globalPath) == canonical(workspacePath);
  }

  Map<String, dynamic> document(SettingScope scope) =>
      scope == SettingScope.session ||
              scope == SettingScope.workspace && sameFile
          ? {}
          : ConfigDocument.open(
                  scope == SettingScope.global ? globalPath : workspacePath,
                  workspace: scope == SettingScope.workspace)
              .values;

  @override
  Map<String, Object?> read(SettingScope scope) {
    if (scope == SettingScope.session) return Map.of(_session);
    final snapshot = scope == SettingScope.workspace && sameFile
        ? ConfigDocument.empty(workspacePath)
        : ConfigDocument.open(
            scope == SettingScope.global ? globalPath : workspacePath,
            workspace: scope == SettingScope.workspace);
    _snapshots[scope] = snapshot;
    final values = snapshot.values;
    final result = <String, Object?>{};
    final plugins = values['plugins'] as Map?;
    final baseline = scope == SettingScope.global && plugins?['enabled'] != null
        ? pluginBaseline((plugins!['enabled'] as List).cast<String>(),
                selectionVersion: plugins['selection_version'] as int? ?? 1)
            .toSet()
        : null;
    for (final definition in catalog.definitions) {
      var value = definition.readConfig?.call(values) ??
          _at(values, definition.configPath);
      if (value == null &&
          definition.id.endsWith('/enabled') &&
          definition.configPath.first == 'plugins' &&
          baseline != null) {
        value = baseline.contains(definition.configPath.last);
      }
      if (value != null) result[definition.id] = value;
    }
    return result;
  }

  void _writeValue(Map<String, dynamic> document,
      SettingDefinition<Object> definition, Object? value) {
    if (definition.writeConfig != null) {
      definition.writeConfig!(document, value);
    } else {
      _put(document, definition.configPath, value);
    }
  }

  ConfigDocument draft(ScopedSettings settings, SettingScope scope) {
    final initial = effectiveDocument(layers: {
      for (final layer in SettingScope.values)
        layer: layer.index < scope.index ? <String, Object?>{} : read(layer),
    });
    return ConfigDocument.draft(_copy(initial), (next) {
      final changed = <String, Object?>{};
      final removed = <String>{};
      for (final definition in catalog.definitions) {
        final before = definition.readConfig?.call(initial) ??
            _at(initial, definition.configPath);
        final after = definition.readConfig?.call(next) ??
            _at(next, definition.configPath);
        if (jsonEncode(before) == jsonEncode(after)) continue;
        if (after == null) {
          removed.add(definition.id);
        } else {
          changed[definition.id] =
              definition.encodeObject(definition.checked(after));
        }
      }
      if (changed.isNotEmpty || removed.isNotEmpty)
        settings.update(scope, changed, remove: removed);
    });
  }

  /// The plugin grid's All column is one action across the three layers.
  void setPluginInAllScopes(ScopedSettings settings,
      SettingDefinition<Object> definition, bool? enabled) {
    if (!definition.id.endsWith('/enabled') ||
        definition.configPath.first != 'plugins') {
      throw ArgumentError('All scopes is only available for plugin toggles');
    }
    if (sameFile) {
      throw StateError(
          'Global and workspace config are the same file; choose a single scope');
    }
    settings.reload();
    final layers = {
      for (final scope in SettingScope.values)
        scope: Map<String, Object?>.of(settings.layer(scope))
    };
    for (final scope in SettingScope.values) {
      if (!definition.scopes.contains(scope))
        throw ArgumentError('Unsupported plugin scope');
      if (enabled == null) {
        layers[scope]!.remove(definition.id);
      } else {
        layers[scope]![definition.id] = definition.encodeObject(enabled);
      }
    }
    final documents = <ConfigDocument>[];
    for (final scope in [SettingScope.global, SettingScope.workspace]) {
      final document = _snapshots[scope]!.fork();
      if (scope == SettingScope.global) {
        document.table('plugins')
          ..remove('enabled')
          ..['selection_version'] = 2;
      }
      for (final field in catalog.definitions) {
        if (field.scopes.contains(scope))
          _writeValue(document.values, field, layers[scope]![field.id]);
      }
      documents.add(document);
    }
    for (final view in SettingScope.values) {
      final effective = effectiveDocument(layers: {
        for (final scope in SettingScope.values)
          scope:
              scope.index < view.index ? <String, Object?>{} : layers[scope]!,
      });
      ConfigDocument.validateValues(effective, descriptors: descriptors);
      validateSelection?.call(effective);
    }
    ConfigDocument.saveScopedBatch(documents);
    _session = layers[SettingScope.session]!;
    onChanged?.call();
    settings.reload();
  }

  /// Effective config retains unknown legacy fields and credentials verbatim.
  Map<String, dynamic> effectiveDocument(
      {Map<SettingScope, Map<String, Object?>>? layers}) {
    layers ??= {for (final scope in SettingScope.values) scope: read(scope)};
    final result = _copy(document(SettingScope.global));
    // Convert legacy replacement lists to independent settings before overlay.
    (result['plugins'] as Map?)?.remove('enabled');
    for (final definition in catalog.definitions) {
      _writeValue(result, definition, null);
      for (final scope in SettingScope.values) {
        if (layers[scope]!.containsKey(definition.id)) {
          _writeValue(result, definition, layers[scope]![definition.id]);
          break;
        }
      }
    }
    return result;
  }

  @override
  void write(SettingScope scope, Map<String, Object?> values) {
    if (scope == SettingScope.workspace && sameFile)
      throw StateError(
          'Global and workspace config are the same file; choose Global scope');
    // Capture the baseline used to calculate this write before validation reads
    // other layers. ConfigDocument refuses to replace a file changed meanwhile.
    final snapshot =
        scope == SettingScope.session ? null : _snapshots[scope]?.fork();
    if (scope != SettingScope.session && snapshot == null)
      throw StateError('Read settings before writing');
    final layers = {
      for (final candidate in SettingScope.values)
        candidate: candidate == scope ? values : read(candidate)
    };
    // Validate every affected context before committing, including masked layers.
    for (final view in SettingScope.values.skip(scope.index)) {
      final candidateLayers = {
        for (final candidate in SettingScope.values)
          candidate: candidate.index < view.index
              ? <String, Object?>{}
              : layers[candidate]!
      };
      final effective = effectiveDocument(layers: candidateLayers);
      ConfigDocument.validateValues(effective, descriptors: descriptors);
      validateSelection?.call(effective);
    }
    final effective = effectiveDocument(layers: layers);
    ConfigDocument.validateValues(effective, descriptors: descriptors);
    validateSelection?.call(effective);
    if (scope == SettingScope.session) {
      _session = Map.of(values);
    } else {
      final document = snapshot!;
      if (scope == SettingScope.global) {
        final plugins = document.values['plugins'] as Map?;
        plugins?.remove('enabled');
        if (plugins != null) plugins['selection_version'] = 2;
      }
      for (final definition in catalog.definitions) {
        if (definition.scopes.contains(scope))
          _writeValue(document.values, definition, values[definition.id]);
      }
      document.saveScoped();
    }
    onChanged?.call();
  }
}
