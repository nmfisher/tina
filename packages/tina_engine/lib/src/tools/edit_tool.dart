import 'dart:io';

import 'tool_input.dart';
import 'edit_preparation.dart';
import 'atomic_write.dart';
import 'file_system.dart';
import 'mutation_lock.dart';
import 'sandbox.dart';
import 'tool.dart';

class EditTool implements Tool {
  /// Captured project root; null retains standalone cwd-relative behavior.
  String? projectRoot;

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
            'files or full rewrites use `write`. On edit_conflict, reread the current '
            'file and submit a corrected exact edit; do not repeat unchanged or '
            'use write to bypass the conflict. Replacement text already present '
            'is a hint to verify completion, not proof of success.',
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

  /// Read and validate before approval without holding the mutation lock while
  /// the user decides. Preparation never writes or creates a backup.
  Future<EditPreparation> prepare(Map<String, dynamic> input) async {
    try {
      final request = EditRequest.fromInput(input, projectRoot);
      return await _withLock(request.path, () => _prepare(request));
    } on ToolValidationException catch (e) {
      return EditPreparation.failed(ToolResult.error(e.message));
    } on SandboxViolation catch (e) {
      return EditPreparation.failed(ToolResult.error(e.message));
    } on FileSystemException catch (e) {
      return EditPreparation.failed(
          ToolResult.error('Unable to read edit target: $e'));
    } on FormatException {
      return EditPreparation.failed(
          ToolResult.error('Edit target could not be decoded as text.'));
    }
  }

  Tool bind(PreparedEdit edit) => _PreparedEditTool(this, edit);

  Future<void> _validate(String path) async {
    final editFs = fs;
    if (editFs is SandboxedFileSystem) await editFs.validatePath(path);
  }

  Future<EditPreparation> _prepare(EditRequest request) async {
    // Confinement precedes existence probes and diagnostic excerpts.
    await _validate(request.path);
    if (!await fs.fileExists(request.path)) {
      return EditPreparation.failed(
          ToolResult.error('File not found: ${request.path}'));
    }
    return prepareEdit(request, await fs.readFileString(request.path));
  }

  Future<T> _withLock<T>(String path, Future<T> Function() action) {
    final lock = mutationLock;
    return lock == null ? action() : lock.withFileLock(path, action);
  }

  Future<ToolResult> _apply(PreparedEdit edit) async {
    final path = edit.request.path;
    String? backupLocation;
    if (backupStore != null) {
      final entry = await backupStore!.backup(path);
      backupLocation = entry?.backupPath;
    }
    await atomicWriteFile(fs, path, edit.updatedText);
    final n = edit.request.replaceAll ? edit.occurrences : 1;
    final message =
        StringBuffer('edited $path ($n replacement${n == 1 ? '' : 's'})');
    if (backupLocation != null)
      message.write('. Backed up previous version to $backupLocation');
    return ToolResult(message.toString());
  }

  Future<ToolResult> _executePrepared(PreparedEdit edit) async {
    final path = edit.request.path;
    try {
      return await _withLock(path, () async {
        await _validate(path);
        if (!await fs.fileExists(path))
          return ToolResult.error('File not found: $path');
        final current = await fs.readFileString(path);
        if (!edit.matchesSnapshot(current)) {
          return EditConflict(EditConflictKind.fileChanged, edit.request,
              current, countEditMatches(current, edit.request.oldString));
        }
        return _apply(edit);
      });
    } on SandboxViolation catch (e) {
      return ToolResult.error(e.message);
    } on FileSystemException catch (e) {
      return ToolResult.error('Unable to apply edit: $e');
    } on FormatException {
      return ToolResult.error('Edit target could not be decoded as text.');
    }
  }

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    // Direct callers prepare and apply under one lock, preserving serialized
    // read/modify/write behavior for concurrent edits of different regions.
    try {
      final request = EditRequest.fromInput(input, projectRoot);
      return await _withLock(request.path, () async {
        final result = await _prepare(request);
        return result.error ?? await _apply(result.edit!);
      });
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    } on SandboxViolation catch (e) {
      return ToolResult.error(e.message);
    } on FileSystemException catch (e) {
      return ToolResult.error('Unable to apply edit: $e');
    } on FormatException {
      return ToolResult.error('Edit target could not be decoded as text.');
    }
  }
}

/// Invocation-local binding: later input mutation cannot change the approved
/// replacement, and concurrent agents never share a pending edit snapshot.
class _PreparedEditTool implements Tool {
  final EditTool owner;
  final PreparedEdit edit;
  _PreparedEditTool(this.owner, this.edit);
  @override
  ToolSchema get schema => owner.schema;
  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) =>
      owner._executePrepared(edit);
}
