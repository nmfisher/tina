import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_input.dart';

/// The invocation approved by the user. Collections are detached and frozen;
/// the environment is complete, not a set of changes to ambient process state.
class ExecutionRequest {
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
  final Map<String, String> environmentOverrides;
  final List<String> writablePaths;
  final int timeoutSeconds;
  final bool shell;

  ExecutionRequest({
    required this.executable,
    required Iterable<String> arguments,
    required this.workingDirectory,
    required Map<String, String> environment,
    required Map<String, String> environmentOverrides,
    required Iterable<String> writablePaths,
    required this.timeoutSeconds,
    required this.shell,
  })  : arguments = List.unmodifiable(arguments),
        environment = Map.unmodifiable(environment),
        environmentOverrides = Map.unmodifiable(environmentOverrides),
        writablePaths = List.unmodifiable(writablePaths);

  String get approvalDescription => '  Working directory: $workingDirectory\n'
      '  Executable: $executable\n'
      '${environmentOverrides.entries.map((e) => '  Environment override: ${e.key}=${e.value}\n').join()}';
}

Map<String, String> executionEnvironmentOverrides(Map<String, dynamic> input) {
  final raw = input['environment'];
  if (raw == null) return const {};
  if (raw is! Map ||
      raw.entries.any((e) =>
          e.key is! String ||
          !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(e.key as String) ||
          e.value is! String ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(e.value as String))) {
    throw const ToolValidationException(
        'environment must map variable names to single-line string values.');
  }
  return Map<String, String>.from(raw);
}

/// Resolve against the same environment and cwd the child will receive.
/// Keep executable symlinks intact: wrappers may depend on their launch path.
String? resolveExecutionExecutable(
    String name, Map<String, String> environment, String workingDirectory) {
  if (name.contains('\x00')) return null;
  final candidates = name.contains('/')
      ? [p.normalize(p.join(workingDirectory, name))]
      : (environment.containsKey('PATH')
              ? environment['PATH']!.split(':')
              : <String>[])
          .map((dir) => p.normalize(p.join(workingDirectory, dir, name)));
  for (final candidate in candidates) {
    final stat = FileStat.statSync(candidate);
    if (stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0) {
      return candidate;
    }
  }
  return null;
}
