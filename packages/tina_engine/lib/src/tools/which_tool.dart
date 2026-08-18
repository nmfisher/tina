import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool.dart';
import 'tool_input.dart';

/// Resolves executable names against PATH — the model-facing replacement for
/// shelling out `which ...` through `bash`. Accepts a comma-separated list so
/// one call can probe several candidates (e.g. `"rg, grep"`). Pure PATH
/// probing: it never touches the project tree, so it needs no sandbox wiring.
class WhichTool implements Tool {
  /// Environment to resolve `PATH` from. Defaults to the process
  /// environment; tests inject a controlled mapping.
  final Map<String, String> environment;

  WhichTool({Map<String, String>? environment})
      : environment = environment ?? Platform.environment;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'which',
        description:
            'Resolve executable names against PATH and report the absolute '
            'path of each, or "not found". Use this to check whether a binary '
            'is installed instead of running `which` via bash.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description':
                  'Executable name, or a comma-separated list of candidates '
                  'to probe in one call, e.g. "rg, grep".',
            },
          },
          'required': ['name'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String names;
    try {
      names = requiredString(input, 'name');
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    final candidates = names
        .split(',')
        .map((n) => n.trim())
        .where((n) => n.isNotEmpty)
        .toList();
    if (candidates.isEmpty) {
      return ToolResult.error('name is required');
    }

    final buf = StringBuffer();
    for (final candidate in candidates) {
      buf.writeln('${_resolve(candidate) ?? 'not found: $candidate'}');
    }
    return ToolResult(buf.toString());
  }

  /// Absolute path of [candidate] when it resolves to an executable file,
  /// null otherwise. A candidate containing a path separator is checked
  /// as-is (the caller supplied the location); a bare name is searched in
  /// each PATH directory in order. PATH entries are ':'-separated on POSIX
  /// and ';' on Windows — NOT `Platform.pathSeparator`.
  String? _resolve(String candidate) {
    if (candidate.contains('/') || candidate.contains('\\')) {
      return _executableAt(candidate) ? _absolute(candidate) : null;
    }
    final listSeparator = Platform.isWindows ? ';' : ':';
    final pathDirs = (environment['PATH'] ?? '')
        .split(listSeparator)
        .where((d) => d.isNotEmpty);
    for (final dir in pathDirs) {
      for (final variant in _nameVariants(candidate)) {
        final full = p.join(dir, variant);
        if (_executableAt(full)) return _absolute(full);
      }
    }
    return null;
  }

  /// The name plus, on Windows, the PATHEXT-style suffixes a bare name can
  /// carry. On POSIX it's just the name itself.
  List<String> _nameVariants(String name) {
    if (!Platform.isWindows) return [name];
    return [
      name,
      '$name.exe',
      '$name.bat',
      '$name.cmd',
    ];
  }

  bool _executableAt(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    // Any executable bit (user/group/other: 0111 octal = 0x49) counts —
    // matching how a shell would consider the file runnable.
    return (stat.mode & 0x49) != 0;
  }

  String _absolute(String path) => File(path).absolute.path;
}
