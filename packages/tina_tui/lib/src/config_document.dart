import 'dart:io';
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

  TinaConfig validate(
      {List<ProviderDescriptor> descriptors = builtinDescriptors,
      void Function(Iterable<String>)? validatePlugins}) {
    final result =
        parseTinaConfig(values, path: path, descriptors: descriptors);
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
      {List<ProviderDescriptor> descriptors = builtinDescriptors,
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
