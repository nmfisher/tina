import 'dart:io';

import 'file_enumerator.dart';
import 'sandbox.dart';
import 'tool.dart';
import 'tool_input.dart';

/// Maximum number of matches returned per call.
const int _defaultMaxResults = 200;

class GlobTool implements Tool {
  /// Source of the file list glob patterns are matched against. Defaults to
  /// [RepoFileEnumerator] (git-aware); tests inject a fake for determinism.
  final FileEnumerator fileEnumerator;

  /// Validates the runtime `path` param against the project root + tina tree.
  /// Glob's `fileEnumerator.enumerate(path)` is a walk the FS seam can't cover,
  /// so [sandbox] asserts the path directly (review H1). Null in tests.
  SandboxedFileSystem? sandbox;

  GlobTool({FileEnumerator? fileEnumerator, this.sandbox})
      : fileEnumerator = fileEnumerator ?? RepoFileEnumerator();

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'glob',
        description:
            'List files matching a glob pattern. Supports `*` (any chars '
            'except `/`), `**` (any number of directories), and `?` (single '
            'non-slash char). Honors .gitignore via `git ls-files` when '
            'available; otherwise walks the tree skipping well-known build '
            'dirs.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'pattern': {
              'type': 'string',
              'description':
                  'Glob pattern, e.g. "*.dart", "lib/**/*.ts", "**/README*".',
            },
            'path': {
              'type': 'string',
              'description':
                  'Root directory to search from. Defaults to the agent cwd.',
            },
            'maxResults': {
              'type': 'integer',
              'description': 'Maximum results to return (default 200).',
            },
          },
          'required': ['pattern'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String pattern;
    final String path;
    final int maxResults;
    try {
      pattern = requiredString(input, 'pattern');
      path = optionalString(input, 'path') ?? Directory.current.path;
      maxResults = optionalInt(input, 'maxResults') ?? _defaultMaxResults;
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    if (!Directory(path).existsSync()) {
      return ToolResult.error('path does not exist: $path');
    }
    // The enumerate walk can't be covered by the FS seam, so assert the
    // runtime path against the sandbox here (review H1). Skipped when sandbox
    // is null. Maps SandboxViolation to a clean error.
    if (sandbox != null) {
      try {
        await sandbox!.validatePath(path);
      } on SandboxViolation catch (e) {
        return ToolResult.error(e.message);
      }
    }

    final files = await fileEnumerator.enumerate(path);
    final matching = <String>[];
    for (final f in files) {
      if (fileGlobMatch(pattern, f)) matching.add(f);
    }

    if (matching.isEmpty) return const ToolResult('(no matches)');
    final shown = matching.length <= maxResults
        ? matching
        : matching.sublist(0, maxResults);
    final buf = StringBuffer();
    for (final f in shown) {
      buf.writeln(f);
    }
    if (matching.length > maxResults) {
      buf.writeln(
          '... (${matching.length - maxResults} more; raise maxResults)');
    }
    return ToolResult(buf.toString());
  }
}
