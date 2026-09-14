import 'dart:convert';

import 'tool.dart';
import 'tool_input.dart';

/// Detached edit arguments shared by validation, preview, and application.
class EditRequest {
  final String path;
  final String oldString;
  final String newString;
  final bool replaceAll;

  const EditRequest(this.path, this.oldString, this.newString, this.replaceAll);

  factory EditRequest.fromInput(
      Map<String, dynamic> input, String? projectRoot) {
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
      throw const ToolValidationException('replaceAll must be a boolean');
    }
    return EditRequest(
        resolveToolPath(path, projectRoot), old, replacement, all);
  }
}

class PreparedEdit {
  final EditRequest request;
  final String _originalText;
  final int occurrences;

  const PreparedEdit._(this.request, this._originalText, this.occurrences);

  bool matchesSnapshot(String text) => text == _originalText;

  String get updatedText => request.replaceAll
      ? _originalText.replaceAll(request.oldString, request.newString)
      : _originalText.replaceFirst(request.oldString, request.newString);
}

class EditPreparation {
  final PreparedEdit? edit;
  final ToolResult? error;
  const EditPreparation.ready(PreparedEdit value)
      : edit = value,
        error = null;
  const EditPreparation.failed(ToolResult value)
      : edit = null,
        error = value;
}

enum EditConflictKind { missingMatch, ambiguousMatch, fileChanged }

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
      EditConflictKind.fileChanged =>
        'File changed since edit preparation: $path',
    };

EditPreparation prepareEdit(EditRequest request, String text) {
  final matches = countEditMatches(text, request.oldString);
  if (matches == 0 || (matches > 1 && !request.replaceAll)) {
    return EditPreparation.failed(EditConflict(
        matches == 0
            ? EditConflictKind.missingMatch
            : EditConflictKind.ambiguousMatch,
        request,
        text,
        matches));
  }
  return EditPreparation.ready(PreparedEdit._(request, text, matches));
}

int countEditMatches(String text, String needle) {
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
