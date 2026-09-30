import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:tina_core/tina_core.dart';
import 'tool_descriptions.dart';

import 'atomic_write.dart';
import 'file_system.dart';
import 'io_file_system.dart';
import 'sandboxed_file_system.dart';
import 'permissions.dart';
import 'tool.dart';
import 'tool_input.dart';

/// The exact-match replace tool. The whole read-validate-write runs under one
/// call: read the current text, count matches, require unique (or replaceAll),
/// then write the updated text atomically.
class EditTool implements Tool {
  /// The workspace root relative paths resolve against. Null retains
  /// standalone cwd-relative behavior.
  final String? workspaceRoot;

  /// The filesystem this tool reads/writes through. Defaults to the real
  /// filesystem.
  final FileSystem fs;

  EditTool({FileSystem? fs, this.workspaceRoot}) : fs = fs ?? IoFileSystem();

  @override
  ToolSchema get schema => const ToolSchema(
        describe: describeEdit,
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

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) async {
    final EditRequest request;
    try {
      request = EditRequest.fromInput(input, workspaceRoot);
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    try {
      // The boundary precedes existence probes: resolve the operation
      // through the sandbox BEFORE reading. Sandboxed only; MemoryFileSystem
      // skips the is-check.
      final editFs = fs;
      if (editFs is SandboxedFileSystem) {
        try {
          await editFs.guard(FileOp.write, request.path);
        } on SandboxViolation catch (e) {
          return ToolResult.error(e.message);
        }
      }
      if (!await fs.fileExists(request.path)) {
        return ToolResult.error('File not found: ${request.path}');
      }
      final current = await fs.readFileString(request.path);
      final matches = countMatches(current, request.oldString);
      if (matches == 0 || (matches > 1 && !request.replaceAll)) {
        return EditConflict(
            matches == 0
                ? EditConflictKind.missingMatch
                : EditConflictKind.ambiguousMatch,
            request,
            current,
            matches);
      }
      final updatedText = request.replaceAll
          ? current.replaceAll(request.oldString, request.newString)
          : current.replaceFirst(request.oldString, request.newString);
      await atomicWriteFile(fs, request.path, updatedText);
      final n = request.replaceAll ? matches : 1;
      return ToolResult(
          'edited ${request.path} ($n replacement${n == 1 ? '' : 's'})');
    } on FileSystemException catch (e) {
      return ToolResult.error('Unable to apply edit: $e');
    } on FormatException {
      return ToolResult.error('Edit target could not be decoded as text.');
    }
  }
}

/// Detached edit arguments shared by validation and application.
class EditRequest {
  final String path;
  final String oldString;
  final String newString;
  final bool replaceAll;

  const EditRequest(this.path, this.oldString, this.newString, this.replaceAll);

  factory EditRequest.fromInput(
      Map<String, dynamic> input, String? workspaceRoot) {
    final path = requiredString(input, 'filePath');
    final old = input['oldString'];
    final replacement = input['newString'];
    if (old is! String || replacement is! String) {
      throw const ToolValidationException(
          'oldString and newString are required strings');
    }
    if (old.isEmpty) {
      throw const ToolValidationException('oldString must not be empty');
    }
    if (old == replacement) {
      throw const ToolValidationException(
          'oldString and newString are identical');
    }
    final all = input['replaceAll'] ?? false;
    if (all is! bool) {
      throw ToolValidationException('replaceAll must be a boolean');
    }
    return EditRequest(
        resolveToolPath(path, workspaceRoot), old, replacement, all);
  }
}

enum EditConflictKind { missingMatch, ambiguousMatch }

/// Structured recovery information is included in content so it survives the
/// tool-result wire format. Current file excerpts are data, never instructions.
class EditConflict extends ToolResult {
  final EditConflictKind kind;
  final String summary;
  EditConflict(this.kind, EditRequest request, String current, int matches)
      : summary = _conflictMessage(kind, request.path, matches),
        super(
            jsonEncode({
              'code': 'edit_conflict',
              'reason': kind.name,
              'filePath': request.path,
              'message': _conflictMessage(kind, request.path, matches),
              'fileModifiedByThisEdit': false,
              'matchCount': matches,
              'replacementTextPresent': request.newString.isNotEmpty &&
                  current.contains(request.newString),
              'lineEndings': current.contains('\r\n')
                  ? 'contains CRLF'
                  : 'LF or no line breaks',
              'currentContext': _context(current, request),
              'recovery': 'Read the current file around this context and verify the intended change. '
                  'If it is already complete, do not edit again. Otherwise submit a corrected '
                  'exact oldString/newString pair, with enough context for a unique match '
                  '(or replaceAll=true only when every occurrence should change). '
                  'Do not retry unchanged or overwrite the file to bypass this conflict. '
                  'Replacement text appearing somewhere in the file is not proof the edit is complete.',
            }),
            isError: true);
}

String _conflictMessage(EditConflictKind kind, String path, int matches) =>
    switch (kind) {
      EditConflictKind.missingMatch => 'oldString not found in $path',
      EditConflictKind.ambiguousMatch =>
        'oldString matches $matches times in $path',
    };

int countMatches(String text, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var offset = 0;
  while (true) {
    final found = text.indexOf(needle, offset);
    if (found < 0) return count;
    count++;
    offset = found + needle.length;
  }
}

Map<String, Object> _context(String text, EditRequest request) {
  // Choose an exact anchor for diagnostics only. Never use this to choose a
  // replacement location or relax matching. Bound both lines and line length.
  var offset = text.indexOf(request.oldString);
  if (offset < 0 && request.newString.isNotEmpty)
    offset = text.indexOf(request.newString);
  if (offset < 0) {
    final firstToken = request.oldString.trim().split(RegExp(r'\s+')).first;
    if (firstToken.isNotEmpty) offset = text.indexOf(firstToken);
  }
  final line =
      offset < 0 ? 0 : '\n'.allMatches(text.substring(0, offset)).length;
  final lines = text.split('\n');
  final start = line > 2 ? line - 2 : 0;
  return {
    'startLine': start + 1,
    'lines': lines
        .skip(start)
        .take(8)
        .map((s) => s.length > 240 ? '${s.substring(0, 240)}…' : s)
        .toList(),
    'note':
        'Bounded excerpt; line numbers are one-based. Read the file for full context.',
  };
}
