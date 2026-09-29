import 'dart:io';
import 'dart:convert';
import 'package:toml/toml.dart';
import 'package:tina_llm/tina_llm.dart';
import 'assembly_config.dart';
import 'configured_provider.dart';

/// Editable snapshot. Unknown legacy tables survive saving; no legacy runtime
/// is loaded. Validation and stale-file detection happen before replacement.
final class ConfigDocument {
  ConfigDocument._(this.path, this.values, this._original);
  final String path;
  final Map<String, dynamic> values;
  String? _original;
  bool get existsOnDisk => _original != null;

  factory ConfigDocument.empty(String path) => ConfigDocument._(path, {}, null);

  factory ConfigDocument.open(String path, {bool workspace = false}) {
    final file = File(path);
    final text = file.existsSync() ? file.readAsStringSync() : null;
    final Map<String, dynamic> values;
    try {
      values = text == null
          ? workspace
              ? <String, dynamic>{}
              : <String, dynamic>{
                  'version': kTinaConfigVersion,
                  'default': <String, dynamic>{'model': kTinaDefaultModel},
                }
          : TomlDocument.parse(text).toMap();
    } catch (_) {
      throw const FormatException('Config is not valid TOML');
    }
    return ConfigDocument._(path, values, text);
  }

  ConfigDocument fork() {
    Object? copy(Object? value) => switch (value) {
          Map value =>
            value.map((key, item) => MapEntry(key as String, copy(item))),
          List value => value.map(copy).toList(),
          _ => value,
        };
    return ConfigDocument._(
        path, copy(values) as Map<String, dynamic>, _original);
  }

  Map<String, dynamic> table(String name) =>
      values.putIfAbsent(name, () => <String, dynamic>{})
          as Map<String, dynamic>;

  /// Empty tables created while browsing do not constitute an edit.
  bool get hasChanges {
    Object? normalize(Object? value) {
      if (value is Map) {
        final result = <String, Object?>{};
        for (final key in value.keys.cast<String>().toList()..sort()) {
          final child = normalize(value[key]);
          if (child is Map && child.isEmpty) continue;
          result[key] = child;
        }
        return result;
      }
      if (value is List) return value.map(normalize).toList();
      return value;
    }

    final original =
        _original == null ? const {} : TomlDocument.parse(_original!).toMap();
    return jsonEncode(normalize(values)) != jsonEncode(normalize(original));
  }

  /// Adopt a table saved by a separate settings control while preserving drafts.
  /// Refuse to absorb unrelated external edits into the snapshot's baseline.
  void refreshTable(String name) {
    final latest = ConfigDocument.open(path);
    final original = _original == null
        ? ConfigDocument.empty(path).values
        : TomlDocument.parse(_original!).toMap();
    String without(Map<String, dynamic> values) =>
        TomlDocument.fromMap(Map<String, dynamic>.from(values)..remove(name))
            .toString();
    if (_original != null && without(original) != without(latest.values)) {
      throw StateError('Config changed on disk; close settings and reopen it.');
    }
    values.remove(name);
    if (latest.values.containsKey(name)) values[name] = latest.values[name];
    _original = latest._original;
  }

  /// Save only this provider's generation controls. Other settings drafts
  /// stay in memory; unrelated disk fields and credentials remain untouched.
  void saveGeneration(String provider, Map<String, dynamic> fields,
      {required List<ProviderDescriptor> descriptors,
      void Function(Iterable<String>)? validatePlugins}) {
    const keys = ['max_output', 'reasoning_effort', 'thinking_budget'];
    final saved = ConfigDocument._(
        path,
        _original == null
            ? <String, dynamic>{}
            : TomlDocument.parse(_original!).toMap(),
        _original);
    final target = saved.table('providers').putIfAbsent(
        provider, () => <String, dynamic>{}) as Map<String, dynamic>;
    void apply(Map<String, dynamic> values) {
      for (final key in keys) {
        if (fields.containsKey(key)) {
          values[key] = fields[key];
        } else {
          values.remove(key);
        }
      }
    }

    apply(target);
    saved.save(descriptors: descriptors, validatePlugins: validatePlugins);
    final draft =
        table('providers').putIfAbsent(provider, () => <String, dynamic>{})
            as Map<String, dynamic>;
    apply(draft);
    _original = saved._original;
  }

  TinaConfig validate(
      {List<ProviderDescriptor>? descriptors,
      void Function(Iterable<String>)? validatePlugins}) {
    final result = parseTinaConfig(values,
        path: path, descriptors: descriptors ?? configuredDescriptors());
    if (result is TinaConfigProblem) throw FormatException(result.problem);
    configuredPolicy(result.config).closeSession();
    validatePlugins?.call([
      'tina/approvals',
      result.config.approvalChannel,
      'tina/tools',
      ...result.config.plugins
    ]);
    return result.config;
  }

  void save(
      {List<ProviderDescriptor>? descriptors,
      void Function(Iterable<String>)? validatePlugins}) {
    validate(descriptors: descriptors, validatePlugins: validatePlugins);
    _write();
  }

  void saveWorkspace({required void Function() validateSelection}) {
    validateWorkspacePlugins(values);
    validateSelection();
    _write();
  }

  void _write() {
    final encoded = TomlDocument.fromMap(values).toString();
    final requested = File(path);
    final file = File(
        requested.existsSync() ? requested.resolveSymbolicLinksSync() : path);
    void checkUnchanged() {
      final current =
          requested.existsSync() ? requested.readAsStringSync() : null;
      if (current != _original)
        throw StateError(
            'Config changed on disk; close settings and reopen it.');
    }

    checkUnchanged();
    file.parent.createSync(recursive: true);
    final staging = file.parent.createTempSync('.tina-config-');
    final pending = File('${staging.path}/config');
    try {
      pending.createSync();
      if (!Platform.isWindows) {
        final result = Process.runSync('chmod', ['600', pending.path]);
        if (result.exitCode != 0)
          throw FileSystemException('Cannot secure config permissions', path);
      }
      pending.writeAsStringSync(encoded, flush: true);
      checkUnchanged();
      pending.renameSync(file.path);
      _original = encoded;
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}
