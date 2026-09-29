import 'dart:io';
import 'package:toml/toml.dart';
import 'typesafe_classifier.dart';

/// Read the existing Typesafe settings independently of conversation providers.
/// Called per input so credentials can change without recreating the session.
TypeSafeConfig? readClassificationConfig(
  String path, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final file = File(path);
  final values = file.existsSync()
      ? TomlDocument.parse(file.readAsStringSync()).toMap()
      : <String, dynamic>{};
  final raw = values['typesafe'];
  if (raw != null && raw is! Map)
    throw const FormatException('Invalid typesafe settings');
  final settings = raw as Map? ?? const {};
  final stored = settings['api_key'] as String?;
  var key = stored != null && stored.trim().isNotEmpty
      ? stored
      : env['TYPESAFE_API_KEY'];
  if (key == null || key.trim().isEmpty) return null;
  final variable = RegExp(r'^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$').firstMatch(key);
  if (variable != null) key = env[variable.group(1)!];
  if (key == null || key.trim().isEmpty) return null;
  return TypeSafeConfig(
    apiKey: key,
    model: settings['model'] as String? ?? 'jev-latest',
    endpoint: settings['endpoint'] == null
        ? null
        : Uri.parse(settings['endpoint'] as String),
  );
}
