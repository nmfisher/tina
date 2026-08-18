import 'dart:io';

import 'sandbox.dart';
import 'tool.dart';
import 'tool_input.dart';

/// Maximum number of entries returned per call.
const int _defaultMaxResults = 200;

/// Lists the entries of a single directory. Read-only, so it needs no
/// permission prompt — the point is that the model inspects a directory
/// without shelling out through `bash`.
class LsTool implements Tool {
  /// Validates the runtime `path` against the project root + tina tree.
  /// Null in tests.
  SandboxedFileSystem? sandbox;

  LsTool({this.sandbox});

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'ls',
        description:
            'List the entries of a directory: type marker (d/-/l), size, and '
            'name per line, directories first. Hidden entries are omitted '
            'unless `all` is true.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Directory to list. Defaults to the agent cwd.',
            },
            'all': {
              'type': 'boolean',
              'description': 'Include hidden (dot) entries. Default false.',
            },
            'maxResults': {
              'type': 'integer',
              'description': 'Maximum entries to return (default 200).',
            },
          },
          'required': [],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String path;
    final bool all;
    final int maxResults;
    try {
      path = optionalString(input, 'path') ?? Directory.current.path;
      all = optionalBool(input, 'all') ?? false;
      maxResults = optionalInt(input, 'maxResults') ?? _defaultMaxResults;
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return ToolResult.error('path does not exist: $path');
    }
    if (type != FileSystemEntityType.directory) {
      return ToolResult.error('not a directory: $path');
    }
    // Like GlobTool: the listing walk can't be covered by the FS seam, so
    // assert the runtime path against the sandbox here. Skipped when sandbox
    // is null. Maps SandboxViolation to a clean error.
    if (sandbox != null) {
      try {
        await sandbox!.validatePath(path);
      } on SandboxViolation catch (e) {
        return ToolResult.error(e.message);
      }
    }

    final entries = Directory(path).listSync(followLinks: false);
    final visible =
        all ? entries : entries.where((e) => !_isHidden(e.path)).toList();
    visible.sort((a, b) {
      final aDir = a.statSync().type == FileSystemEntityType.directory;
      final bDir = b.statSync().type == FileSystemEntityType.directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return _baseName(a.path).compareTo(_baseName(b.path));
    });

    if (visible.isEmpty) return const ToolResult('(empty)');
    final shown = visible.length <= maxResults
        ? visible
        : visible.sublist(0, maxResults);
    final buf = StringBuffer();
    for (final e in shown) {
      final stat = e.statSync();
      final marker = switch (stat.type) {
        FileSystemEntityType.directory => 'd',
        FileSystemEntityType.link => 'l',
        _ => '-',
      };
      final size = stat.type == FileSystemEntityType.directory
          ? '-'
          : stat.size.toString();
      buf.writeln('$marker ${size.padLeft(10)}  ${_baseName(e.path)}');
    }
    if (visible.length > maxResults) {
      buf.writeln(
          '... (${visible.length - maxResults} more; raise maxResults)');
    }
    return ToolResult(buf.toString());
  }
}

bool _isHidden(String path) => _baseName(path).startsWith('.');

String _baseName(String path) {
  final normalized = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final slash = normalized.lastIndexOf(Platform.pathSeparator);
  return slash == -1 ? normalized : normalized.substring(slash + 1);
}
