import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

final class McpServerConfig {
  McpServerConfig(this.name, Map<String, dynamic> values)
      : values = Map.unmodifiable(values) {
    if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(name)) {
      throw const FormatException(
          'MCP server names must be lowercase identifiers');
    }
    const keys = {
      'command',
      'args',
      'env',
      'cwd',
      'url',
      'headers',
      'enabled',
      'timeout_ms'
    };
    if (values.keys.any((key) => !keys.contains(key))) {
      throw FormatException('Unknown setting in mcp.servers.$name');
    }
    if (values['enabled'] != null && values['enabled'] is! bool) {
      throw FormatException('mcp.servers.$name.enabled must be boolean');
    }
    final command = values['command'], url = values['url'];
    if ((command == null) == (url == null)) {
      throw FormatException(
          'mcp.servers.$name needs exactly one of command or url');
    }
    if (command != null && (command is! String || command.trim().isEmpty)) {
      throw FormatException('mcp.servers.$name.command must be nonempty');
    }
    if (url != null) {
      final uri = url is String ? Uri.tryParse(url) : null;
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.fragment.isNotEmpty) {
        throw FormatException(
            'mcp.servers.$name.url must be an HTTP(S) endpoint');
      }
      if (['command', 'args', 'env', 'cwd'].any(values.containsKey)) {
        throw FormatException('HTTP MCP servers cannot have process settings');
      }
    } else if (values.containsKey('headers')) {
      throw FormatException('stdio MCP servers cannot have HTTP headers');
    }
    if (values['args'] != null &&
        (values['args'] is! List ||
            (values['args'] as List).any((v) => v is! String))) {
      throw FormatException('mcp.servers.$name.args must be strings');
    }
    if (values['cwd'] != null && values['cwd'] is! String) {
      throw FormatException('mcp.servers.$name.cwd must be a path');
    }
    for (final field in ['env', 'headers']) {
      final table = values[field];
      if (table != null &&
          (table is! Map ||
              table.entries
                  .any((e) => e.key is! String || e.value is! String))) {
        throw FormatException(
            'mcp.servers.$name.$field must map names to strings');
      }
    }
    for (final key in headers.keys) {
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key) ||
          {
            'accept',
            'content-type',
            'host',
            'content-length',
            'mcp-session-id',
            'mcp-protocol-version'
          }.contains(key.toLowerCase())) {
        throw FormatException('Invalid or reserved MCP header name: $key');
      }
    }
    final timeout = values['timeout_ms'];
    if (timeout != null && (timeout is! int || timeout < 0)) {
      throw FormatException(
          'mcp.servers.$name.timeout_ms must be nonnegative (0 disables it)');
    }
  }
  final String name;
  final Map<String, dynamic> values;
  bool get enabled => values['enabled'] as bool? ?? true;
  String? get command => values['command'] as String?;
  List<String> get arguments =>
      List<String>.from(values['args'] as List? ?? const []);
  String? get url => values['url'] as String?;
  Map<String, String> get environment =>
      Map<String, String>.from(values['env'] as Map? ?? const {});
  Map<String, String> get headers =>
      Map<String, String>.from(values['headers'] as Map? ?? const {});
  Duration? get timeout => values['timeout_ms'] == 0
      ? null
      : Duration(milliseconds: values['timeout_ms'] as int? ?? 60000);
  String get fingerprint => jsonEncode(values);
  String directory(String workspace) =>
      p.normalize(p.join(workspace, values['cwd'] as String? ?? '.'));
  McpServerConfig withValue(String key, Object? value) =>
      McpServerConfig(name, {
        ...values,
        key: value,
      });

  /// Credentials stay in environment variables; missing variables fail closed.
  static String expand(String text, Map<String, String> environment) =>
      text.replaceAllMapped(RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}'), (match) {
        final value = environment[match[1]];
        if (value == null)
          throw FormatException(
              'MCP environment variable ${match[1]} is not set');
        return value;
      });

  static List<McpServerConfig> parse(Object? value) {
    if (value == null) return const [];
    if (value is! Map ||
        value.keys.any((k) => k != 'servers') ||
        (value['servers'] != null && value['servers'] is! Map)) {
      throw const FormatException('[mcp] supports a servers table');
    }
    return [
      for (final entry in (value['servers'] as Map? ?? const {}).entries)
        if (entry.key is String && entry.value is Map)
          McpServerConfig(entry.key as String,
              Map<String, dynamic>.from(entry.value as Map))
        else
          throw const FormatException('MCP server definitions must be tables'),
    ];
  }
}

/// Plugin-owned storage. Preserve other plugins' and providers' config tables.
final class McpConfigStore {
  McpConfigStore(this.path);
  final String path;
  List<McpServerConfig> read() => McpServerConfig.parse(_document()['mcp']);
  Map<String, dynamic> _document() => File(path).existsSync()
      ? TomlDocument.parse(File(path).readAsStringSync()).toMap()
      : {};
  void save(McpServerConfig server) {
    final file = File(path);
    final original = file.existsSync() ? file.readAsStringSync() : null;
    final document = original == null
        ? <String, dynamic>{}
        : TomlDocument.parse(original).toMap();
    final table = document.putIfAbsent('mcp', () => <String, dynamic>{}) as Map;
    final servers =
        table.putIfAbsent('servers', () => <String, dynamic>{}) as Map;
    servers[server.name] = Map<String, dynamic>.from(server.values);
    McpServerConfig.parse(table);
    file.parent.createSync(recursive: true);
    final destination =
        File(file.existsSync() ? file.resolveSymbolicLinksSync() : path);
    final staging = destination.parent.createTempSync('.tina-mcp-');
    try {
      final pending = File(p.join(staging.path, 'config'));
      pending.writeAsStringSync(TomlDocument.fromMap(document).toString(),
          flush: true);
      if (!Platform.isWindows &&
          Process.runSync('chmod', ['600', pending.path]).exitCode != 0) {
        throw const FileSystemException('Cannot secure MCP config permissions');
      }
      if ((file.existsSync() ? file.readAsStringSync() : null) != original) {
        throw StateError('Config changed on disk; reopen settings');
      }
      pending.renameSync(destination.path);
    } finally {
      staging.deleteSync(recursive: true);
    }
  }
}
