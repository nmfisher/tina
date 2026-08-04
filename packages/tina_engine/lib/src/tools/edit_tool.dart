import 'atomic_write.dart';
import 'file_system.dart';
import 'mutation_lock.dart';
import 'sandbox.dart';
import 'tool.dart';

class EditTool implements Tool {
  /// The filesystem this tool reads/writes through. Mutable so app composition
  /// can inject a [SandboxedFileSystem] once. Defaults to the real filesystem.
  late FileSystem fs;

  /// When set (at composition), edits back up the previous file first and land
  /// atomically (temp + rename) so a crash can't leave the file half-written.
  /// Tests that don't inject a store fall back to a plain write.
  BackupStore? backupStore;

  /// When set (at composition, shared with [WriteTool]), serializes same-file
  /// read-modify-writes across concurrent agents so two edits can't lose an
  /// update. Null in tests that don't inject one (then edits run unlocked, as
  /// before).
  FileMutationLock? mutationLock;

  EditTool({FileSystem? fs, this.backupStore}) : fs = fs ?? IoFileSystem();

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'edit',
        description:
            'Replace an exact string in a file. `oldString` must match '
            'verbatim, including whitespace. Errors if `oldString` is not '
            'present or not unique (unless `replaceAll` is true). For new '
            'files or full rewrites use `write`.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'filePath': {'type': 'string'},
            'oldString': {
              'type': 'string',
              'description':
                  'Exact substring to replace. Include enough surrounding '
                  'context to make it unique.',
            },
            'newString': {
              'type': 'string',
              'description': 'Replacement text. Must differ from oldString.',
            },
            'replaceAll': {
              'type': 'boolean',
              'description':
                  'If true, replace every occurrence; otherwise the match '
                  'must be unique. Defaults to false.',
            },
          },
          'required': ['filePath', 'oldString', 'newString'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final path = input['filePath'] as String?;
    final oldStr = input['oldString'] as String?;
    final newStr = input['newString'] as String?;
    final replaceAll = (input['replaceAll'] as bool?) ?? false;

    if (path == null || path.isEmpty) {
      return ToolResult.error('filePath is required');
    }
    if (oldStr == null || newStr == null) {
      return ToolResult.error('oldString and newString are required');
    }
    if (oldStr == newStr) {
      return ToolResult.error('oldString and newString are identical');
    }
    // Validate against the sandbox BEFORE any existence probe or backup, so an
    // out-of-project target can't leak into the backup store (and its existence
    // can't be probed). Sandboxed only; MemoryFileSystem skips the is-check.
    final editFs = fs;
    if (editFs is SandboxedFileSystem) {
      try {
        await editFs.validatePath(path);
      } on SandboxViolation catch (e) {
        return ToolResult.error(e.message);
      }
    }
    Future<ToolResult> mutate() async {
      if (!await fs.fileExists(path)) {
        return ToolResult.error('File not found: $path');
      }
      final text = await fs.readFileString(path);
      final occurrences = _countOccurrences(text, oldStr);
      if (occurrences == 0) {
        return ToolResult.error('oldString not found in $path');
      }
      if (occurrences > 1 && !replaceAll) {
        return ToolResult.error(
          'oldString matches $occurrences times in $path. Provide more '
          'context to make it unique, or set replaceAll=true.',
        );
      }
      final updated = replaceAll
          ? text.replaceAll(oldStr, newStr)
          : text.replaceFirst(oldStr, newStr);
      // Back up the pre-edit version, then land the edit atomically.
      String? backupLocation;
      if (backupStore != null) {
        final entry = await backupStore!.backup(path);
        backupLocation = entry?.backupPath;
      }
      await atomicWriteFile(fs, path, updated);
      final n = replaceAll ? occurrences : 1;
      final msg =
          StringBuffer('edited $path ($n replacement${n == 1 ? '' : 's'})');
      if (backupLocation != null) {
        msg.write('. Backed up previous version to $backupLocation');
      }
      return ToolResult(msg.toString());
    }

    // Hold the per-file lock across the read-modify-write so a concurrent edit
    // or write of the same file (another agent) can't interleave and lose an
    // update. Unlocked when no lock is configured (tests).
    final lock = mutationLock;
    return lock == null ? mutate() : lock.withFileLock(path, mutate);
  }

  int _countOccurrences(String text, String needle) {
    if (needle.isEmpty) return 0;
    var count = 0;
    var idx = 0;
    while (true) {
      final found = text.indexOf(needle, idx);
      if (found < 0) break;
      count++;
      idx = found + needle.length;
    }
    return count;
  }
}
