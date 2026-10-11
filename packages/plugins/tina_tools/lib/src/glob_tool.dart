import 'dart:io';

import 'package:tina_core/tina_core.dart';
import 'tool_descriptions.dart';

import 'glob.dart';
import 'io_file_system.dart';
import 'sandboxed_file_system.dart';
import 'tool.dart';
import 'tool_file_system.dart';
import 'tool_input.dart';

/// Maximum number of matches returned per call.
const int _defaultMaxResults = 200;

class GlobTool implements Tool {
  /// The workspace root relative paths resolve against. Null retains
  /// standalone cwd-relative behavior.
  final String? workspaceRoot;

  /// Validates the runtime `path` param against the project root + tina tree.
  /// Glob's walk is a `dart:io` walk the FS seam can't cover, so [sandbox]
  /// asserts the path directly. Null in tests.
  final SandboxedFileSystem? sandbox;

  /// Resolves and routes every path: workspace resolution and the sandbox
  /// boundary live here, not in the tool body.
  final ToolFileSystem _routes;

  GlobTool({this.workspaceRoot, this.sandbox})
      : _routes = ToolFileSystem(const IoFileSystem(),
            workspaceRoot: workspaceRoot, sandbox: sandbox);

  @override
  ToolSchema get schema => const ToolSchema(
        describe: describeGlob,
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
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final String pattern;
    final String path;
    final int maxResults;
    try {
      pattern = requiredString(input, 'pattern');
      path = _routes.resolve(optionalString(input, 'path') ??
          workspaceRoot ??
          Directory.current.path);
      maxResults = optionalInt(input, 'maxResults') ?? _defaultMaxResults;
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    // A file root is valid: it enumerates to itself, so it should be
    // pattern-matched like any enumerated entry rather than rejected here.
    if (!Directory(path).existsSync() && !File(path).existsSync()) {
      return ToolResult.error('path does not exist: $path');
    }
    // The walk can't be covered by the FS seam, so the wrapper resolves the
    // read through the boundary here.
    final refusal = await _routes.guard(FileOp.read, path);
    if (refusal != null) return refusal;

    final files = walkFiles(path);
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
