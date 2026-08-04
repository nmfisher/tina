import 'dart:convert';

import 'file_system.dart';
import 'sandbox.dart';
import 'tool.dart';

class ReadTool implements Tool {
  /// The filesystem this tool reads through. Mutable so app composition can
  /// inject a [SandboxedFileSystem] once (the codebase's established injection
  /// style). Defaults to the real filesystem when constructed with no argument,
  /// so callers — including tests that inject [MemoryFileSystem] — are
  /// unchanged.
  late FileSystem fs;

  ReadTool({FileSystem? fs}) : fs = fs ?? IoFileSystem();

  static const int defaultLimit = 2000;
  static const int byteCap = 50 * 1024;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'read',
        description:
            'Read a text file. Returns lines numbered "N: <line>". Default '
            'limit is 2000 lines and ~50KB. Use offset/limit (1-indexed) for '
            'larger files.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'filePath': {
              'type': 'string',
              'description': 'Absolute or cwd-relative path.',
            },
            'offset': {
              'type': 'integer',
              'description': '1-indexed first line to include.',
            },
            'limit': {
              'type': 'integer',
              'description': 'Maximum number of lines to include.',
            },
          },
          'required': ['filePath'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final path = input['filePath'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('filePath is required');
    }
    // Validate against the sandbox BEFORE any existence probe, so an
    // out-of-project target's existence can't be probed. Sandboxed only;
    // MemoryFileSystem skips the is-check.
    final readFs = fs;
    if (readFs is SandboxedFileSystem) {
      try {
        await readFs.validatePath(path);
      } on SandboxViolation catch (e) {
        return ToolResult.error(e.message);
      }
    }
    if (!await fs.fileExists(path)) {
      return ToolResult.error('File not found: $path');
    }
    final bytes = await fs.readFileBytes(path);
    if (_looksBinary(bytes)) {
      return ToolResult.error('File appears to be binary: $path');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final lines = const LineSplitter().convert(text);

    final offset = (input['offset'] as int?) ?? 1;
    final limit = (input['limit'] as int?) ?? defaultLimit;
    if (offset < 1) {
      return ToolResult.error('offset must be >= 1');
    }
    final startIdx = offset - 1;
    final endIdx = (startIdx + limit).clamp(0, lines.length);
    if (startIdx >= lines.length) {
      return ToolResult('(empty: offset $offset is past EOF; file has '
          '${lines.length} lines)');
    }

    final width = endIdx.toString().length;
    final out = StringBuffer();
    var bytesWritten = 0;
    var lastIncluded = startIdx;
    for (var i = startIdx; i < endIdx; i++) {
      final lineNo = (i + 1).toString().padLeft(width);
      final entry = '$lineNo: ${lines[i]}\n';
      if (bytesWritten + entry.length > byteCap) {
        out.write('… (truncated at $byteCap bytes)\n');
        break;
      }
      out.write(entry);
      bytesWritten += entry.length;
      lastIncluded = i;
    }
    if (lastIncluded + 1 < lines.length && bytesWritten <= byteCap) {
      out.write(
          '… (${lines.length - (lastIncluded + 1)} more lines; use offset/limit)\n');
    }
    return ToolResult(out.toString());
  }

  bool _looksBinary(List<int> bytes) {
    final n = bytes.length < 512 ? bytes.length : 512;
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }
}
