import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'file_system.dart';
import 'mutation_lock.dart';
import 'sandbox.dart';
import 'tool.dart';

class WriteTool implements Tool {
  /// The filesystem this tool writes through. Mutable so app composition can
  /// inject a [SandboxedFileSystem] once. Defaults to the real filesystem.
  late FileSystem fs;

  /// When set (at composition), writes are atomic (temp + rename) and back up
  /// the previous file first. Tests that don't inject a store fall back to a
  /// plain write.
  BackupStore? backupStore;

  /// When set (at composition, shared with [EditTool]), serializes same-file
  /// writes against concurrent edits/writes from other agents. Null in tests.
  FileMutationLock? mutationLock;

  WriteTool({FileSystem? fs, this.backupStore}) : fs = fs ?? IoFileSystem();

  @override
  ToolSchema get schema => const ToolSchema(
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
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final path = input['filePath'] as String?;
    final content = input['content'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.error('filePath is required');
    }
    if (content == null) {
      return ToolResult.error('content is required');
    }
    // Validate against the sandbox BEFORE any existence probe or backup, so an
    // out-of-project target can't leak into the backup store (and its existence
    // can't be probed). Sandboxed only; MemoryFileSystem skips the is-check.
    final writeFs = fs;
    if (writeFs is SandboxedFileSystem) {
      try {
        await writeFs.validatePath(path);
      } on SandboxViolation catch (e) {
        return ToolResult.error(e.message);
      }
    }
    final dir = p.dirname(path);
    if (!await fs.directoryExists(dir)) {
      await fs.createDirectory(dir, recursive: true);
    }
    Future<ToolResult> doWrite() async {
      final existed = await fs.fileExists(path);
      // Backup before overwrite, then write atomically (temp in the same dir +
      // rename) so a crash can't leave the file half-written. Both steps are
      // no-ops when there's no backupStore (e.g. tests injecting MemoryFileSystem).
      String? backupLocation;
      if (backupStore != null && existed) {
        final entry = await backupStore!.backup(path);
        backupLocation = entry?.backupPath;
      }
      await atomicWriteFile(fs, path, content);
      final action = existed ? 'overwrote' : 'created';
      final msg = StringBuffer('$action $path (${content.length} bytes)');
      if (backupLocation != null) {
        msg.write('. Backed up previous version to $backupLocation');
      }
      return ToolResult(msg.toString());
    }

    // Hold the per-file lock across the backup+write so a concurrent edit or
    // write of the same file (another agent) can't interleave. Unlocked when no
    // lock is configured (tests). Parent-dir creation above is idempotent and
    // stays outside the lock.
    final lock = mutationLock;
    return lock == null ? doWrite() : lock.withFileLock(path, doWrite);
  }
}
