import 'package:path/path.dart' as p;
import 'package:tina_core/tina_core.dart';
import 'tool_descriptions.dart';

import 'atomic_write.dart';
import 'file_system.dart';
import 'io_file_system.dart';
import 'tool.dart';
import 'tool_file_system.dart';

class WriteTool implements Tool {
  /// The workspace root relative paths resolve against. Null retains
  /// standalone cwd-relative behavior.
  final String? workspaceRoot;

  /// The filesystem this tool writes through. Defaults to the real filesystem.
  final FileSystem fs;

  /// Resolves and routes every path: workspace resolution and the sandbox
  /// boundary live here, not in the tool body.
  final ToolFileSystem _routes;

  WriteTool({FileSystem? fs, this.workspaceRoot})
      : fs = fs ?? IoFileSystem(),
        _routes = ToolFileSystem.of(fs ?? IoFileSystem(),
            workspaceRoot: workspaceRoot);

  @override
  ToolSchema get schema => const ToolSchema(
        describe: describeWrite,
        name: 'write',
        description:
            'Create or overwrite a file with the given content. Parent '
            'directories are created if missing. Use `edit` for surgical '
            'changes to existing files.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'filePath': {
              'type': 'string',
              'description': 'Absolute or cwd-relative path.',
            },
            'content': {
              'type': 'string',
              'description': 'Full file contents to write.',
            },
          },
          'required': ['filePath', 'content'],
        },
      );

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final rawPath = input['filePath'] as String?;
    final content = input['content'] as String?;
    if (rawPath == null || rawPath.isEmpty) {
      return ToolResult.error('filePath is required');
    }
    if (content == null) {
      return ToolResult.error('content is required');
    }
    // The boundary precedes any existence probe: resolve and route the
    // operation through the wrapper BEFORE probing. run() makes the decision
    // (structural checks + table/approver) once at entry; the seam methods
    // below re-guard internally and recognize that decision instead of
    // asking again.
    final path = _routes.resolve(rawPath);
    return _routes.run(
        FileOp.write, path, () => _writeUnsandboxed(path, content));
  }

  Future<ToolResult> _writeUnsandboxed(String path, String content) async {
    final dir = p.dirname(path);
    if (!await fs.directoryExists(dir)) {
      await fs.createDirectory(dir, recursive: true);
    }
    final existed = await fs.fileExists(path);
    // Atomic: write to a same-dir temp, then rename, so a crash can't leave
    // the file half-written. No backup store — one loop, git is the recovery.
    await atomicWriteFile(fs, path, content);
    final action = existed ? 'overwrote' : 'created';
    return ToolResult('$action $path (${content.length} bytes)');
  }
}
