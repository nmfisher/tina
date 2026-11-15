/// The install cache (~/.tina/plugins/<name>/<version>/) and the
/// [plugin-registry] section of the global config.
library tina_plugin_registry;

import 'dart:convert';
import 'dart:io';

/// The cache: versioned directories holding the verified component bytes
/// plus an install.json record (entry, approved grants, install time).
class PluginCache {
  PluginCache({required this.root});

  final Directory root;

  Directory pluginDir(String name, String version) {
    final sanitized = name.replaceAll('/', '__');
    return Directory(
        '${root.path}${Platform.pathSeparator}$sanitized${Platform.pathSeparator}$version');
  }

  File componentFile(String name, String version) => File(
      '${pluginDir(name, version).path}${Platform.pathSeparator}component.wasm');

  Future<void> install(
      {required String name,
      required String version,
      required List<int> componentBytes,
      required Map<String, Object?> entry,
      required List<String> grants,
      required List<String> deniedIds}) async {
    final dir = pluginDir(name, version);
    await dir.create(recursive: true);
    await File(
            '${dir.path}${Platform.pathSeparator}component.wasm')
        .writeAsBytes(componentBytes, flush: true);
    final record = {
      'name': name,
      'version': version,
      'grants': grants,
      'denied': deniedIds,
      'installedAt': DateTime.now().toUtc().toIso8601String(),
      'entry': entry,
    };
    await File('${dir.path}${Platform.pathSeparator}install.json')
        .writeAsString(json.encode(record), flush: true);
  }

  Future<void> remove(String name) async {
    final parent = Directory(
        '${root.path}${Platform.pathSeparator}${name.replaceAll('/', '__')}');
    if (await parent.exists()) {
      await parent.delete(recursive: true);
    }
  }

  /// Lists installed plugins from the cache (name, version, grants).
  Future<List<InstalledRecord>> list() async {
    if (!await root.exists()) return const [];
    final records = <InstalledRecord>[];
    await for (final nameDir in root.list()) {
      if (nameDir is! Directory) continue;
      await for (final versionDir in nameDir.list()) {
        if (versionDir is! Directory) continue;
        final manifest = File(
            '${versionDir.path}${Platform.pathSeparator}install.json');
        if (!await manifest.exists()) continue;
        try {
          final decoded =
              json.decode(await manifest.readAsString()) as Map<String, Object?>;
          records.add(InstalledRecord(
            name: decoded['name'] is String ? decoded['name'] as String : '',
            version:
                decoded['version'] is String ? decoded['version'] as String : '',
            grants: (decoded['grants'] as List?)?.cast<String>() ?? const [],
            denied: (decoded['denied'] as List?)?.cast<String>() ?? const [],
            componentPath: File(
                    '${versionDir.path}${Platform.pathSeparator}component.wasm')
                .path,
          ));
        } on FormatException {
          // A corrupted record is listed without metadata rather than
          // breaking the listing.
          continue;
        }
      }
    }
    records.sort((a, b) => a.name.compareTo(b.name));
    return records;
  }
}

class InstalledRecord {
  const InstalledRecord({
    required this.name,
    required this.version,
    required this.grants,
    required this.denied,
    required this.componentPath,
  });

  final String name;
  final String version;
  final List<String> grants;
  final List<String> denied;
  final String componentPath;
}

/// Reads and writes the `[plugin-registry]` table of the global config
/// (TOML). v1 keeps a dedicated line-based block editor: the section owns
/// `url`, `key`, `active`, and one `installed` entry line per plugin.
class RegistryConfig {
  RegistryConfig(this.configPath);

  final File configPath;

  /// Parses the current section. The format:
  ///
  /// ```toml
  /// [plugin-registry]
  /// url = "http://127.0.0.1:8642"
  /// key = "<base64 ed25519 public key>"
  /// active = "tina/wasm-prompt"
  /// installed = ["demo/entity-decode@0.1.0", "tina/wasm-prompt@0.1.0"]
  /// ```
  RegistryConfigData read() {
    if (!configPath.existsSync()) return RegistryConfigData();
    final data = RegistryConfigData();
    String? section;
    for (final rawLine in configPath.readAsLinesSync()) {
      final line = rawLine.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1);
        continue;
      }
      if (section != 'plugin-registry' || !line.contains('=')) continue;
      final split = line.indexOf('=');
      final key = line.substring(0, split).trim();
      final value = line.substring(split + 1).trim();
      switch (key) {
        case 'url':
          data.url = _unquote(value);
        case 'key':
          data.key = _unquote(value);
        case 'active':
          data.active = _unquote(value);
        case 'installed':
          data.installed = _parseStringArray(value);
      }
    }
    return data;
  }

  /// Writes the section back into the config, replacing an existing
  /// [plugin-registry] block or appending one. Other sections and lines
  /// pass through untouched.
  void write(RegistryConfigData data) {
    final lines = configPath.existsSync()
        ? configPath.readAsLinesSync()
        : <String>[];
    final output = <String>[];
    var inSection = false;
    var replaced = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        if (inSection) {
          // The section ended: emit ours here once.
          inSection = false;
          if (!replaced) {
            output.addAll(_sectionLines(data));
            replaced = true;
          }
        }
        if (trimmed == '[plugin-registry]') {
          inSection = true;
          continue;
        }
      }
      if (inSection) continue; // drop old section lines
      output.add(line);
    }
    if (inSection && !replaced) {
      // The old section ran to end-of-file; emit the replacement here.
      output.addAll(_sectionLines(data));
      replaced = true;
    }
    if (!replaced) {
      // Append at the end, after a blank separator.
      if (output.isNotEmpty && output.last.trim().isNotEmpty) {
        output.add('');
      }
      output.addAll(_sectionLines(data));
    }
    configPath.parent.createSync(recursive: true);
    configPath.writeAsStringSync(output.join('\n') + (output.isEmpty ? '' : '\n'),
        flush: true);
  }

  List<String> _sectionLines(RegistryConfigData data) {
    final lines = <String>['[plugin-registry]'];
    if (data.url != null) lines.add('url = ${_quote(data.url!)}');
    if (data.key != null) lines.add('key = ${_quote(data.key!)}');
    if (data.active != null) lines.add('active = ${_quote(data.active!)}');
    if (data.installed.isNotEmpty) {
      lines.add(
          'installed = [${data.installed.map(_quote).join(', ')}]');
    }
    return lines;
  }
}

class RegistryConfigData {
  RegistryConfigData();

  String? url;
  String? key;
  String? active;
  List<String> installed = [];

  bool get isConfigured => url != null && key != null;
}

String _quote(String value) =>
    '"${value.replaceAll(r'\\', r'\\').replaceAll('"', r'\"')}"';

String _unquote(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed
        .substring(1, trimmed.length - 1)
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\');
  }
  return trimmed;
}

List<String> _parseStringArray(String value) {
  final inner = value.trim();
  if (!inner.startsWith('[') || !inner.endsWith(']')) return const [];
  return RegExp(r'"((?:[^"\\]|\\.)*)"')
      .allMatches(inner)
      .map((m) => _unquote(m.group(1)!))
      .toList();
}
