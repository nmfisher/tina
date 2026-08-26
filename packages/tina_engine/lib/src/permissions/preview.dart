import 'dart:convert';
import 'dart:io';

/// Maximum lines we'll render in any single preview. Edits with thousand-line
/// `oldString` blocks get clipped — the user can rely on git/their editor
/// for the full diff; the preview is just a "skim before approving" pane.
const int _maxPreviewLines = 60;

/// Bigger files than this skip the LCS pass for `write` previews — O(m*n)
/// would be slow, and the diff would be unreadable anyway.
const int _maxDiffLineCount = 2000;

/// A single rendered line of a tool-call preview. The asker turns each entry
/// into chat output with appropriate colors; keeping it as data (not pre-
/// colored strings) makes preview generation unit-testable.
sealed class PreviewEntry {
  const PreviewEntry();
}

class PreviewHeader extends PreviewEntry {
  final String text;
  const PreviewHeader(this.text);
}

class PreviewAdded extends PreviewEntry {
  final String text;
  const PreviewAdded(this.text);
}

class PreviewRemoved extends PreviewEntry {
  final String text;
  const PreviewRemoved(this.text);
}

class PreviewContext extends PreviewEntry {
  final String text;
  const PreviewContext(this.text);
}

class PreviewSeparator extends PreviewEntry {
  const PreviewSeparator();
}

/// Produce a structured preview of what a tool call is about to do. Returns
/// an empty list for tools that don't benefit from a preview (bash, read,
/// search). Never throws — file errors degrade to a one-line header.
Future<List<PreviewEntry>> previewToolCall(
  String tool,
  Map<String, dynamic> input,
) async {
  switch (tool) {
    case 'edit':
      return _editPreview(input);
    case 'write':
      return await _writePreview(input);
    case 'launch_workflow':
      return _launchWorkflowPreview(input);
    default:
      return const [];
  }
}

/// Preview for `launch_workflow`: the workflow name plus the task being handed
/// to it — the decision the user approves is "run this task through this
/// graph", so that is what the modal shows. (The agent's streamed prose before
/// the call is model behavior, not a contract; the approval itself must carry
/// the information.)
List<PreviewEntry> _launchWorkflowPreview(Map<String, dynamic> input) {
  final task = (input['input'] as String?)?.trim() ?? '';
  final workflow = ((input['workflow'] as String?)?.trim().isEmpty ?? true)
      ? 'default'
      : (input['workflow'] as String).trim();
  final lines = const LineSplitter().convert(task);
  var first = lines.isEmpty ? '' : lines.first.trim();
  if (first.length > 80) first = '${first.substring(0, 77)}…';
  final label = first.isEmpty
      ? 'workflow "$workflow"'
      : 'workflow "$workflow" — $first';
  if (lines.length <= 1) return [PreviewHeader(label)];
  return [
    PreviewHeader(label),
    PreviewContext('… (${lines.length - 1} more lines of task text)'),
  ];
}

List<PreviewEntry> _editPreview(Map<String, dynamic> input) {
  final path = input['filePath'] as String? ?? '(no path)';
  final oldStr = input['oldString'] as String? ?? '';
  final newStr = input['newString'] as String? ?? '';
  final replaceAll = (input['replaceAll'] as bool?) ?? false;
  final header =
      replaceAll ? 'edit: $path (replaceAll)' : 'edit: $path';

  final oldLines = const LineSplitter().convert(oldStr);
  final newLines = const LineSplitter().convert(newStr);

  final out = <PreviewEntry>[PreviewHeader(header)];
  // The cap is split so neither side can starve the other. Sharing one
  // budget meant a 60-line oldString consumed it entirely and the user
  // approved an edit whose added half never rendered.
  final removedBudget =
      _sideCap(oldLines.length, newLines.length);
  final addedBudget = _maxPreviewLines - removedBudget;
  _appendBounded(out, oldLines, removedBudget, 'removed',
      (s) => PreviewRemoved(s));
  _appendBounded(out, newLines, addedBudget, 'added',
      (s) => PreviewAdded(s));
  return out;
}

/// Per-side line budget for the edit preview: half the cap each, with any
/// odd-cap remainder going to the shorter side. Fixed budgets — rather than
/// letting the second block spend whatever the first left over — are the
/// point: a long oldString used to eat the whole cap before the added side
/// rendered a single line.
int _sideCap(int oldCount, int newCount) {
  final half = _maxPreviewLines ~/ 2;
  final remainder = _maxPreviewLines - half * 2;
  if (remainder == 0 || oldCount == newCount) return half;
  return oldCount < newCount ? half + remainder : half;
}

void _appendBounded<T>(
  List<PreviewEntry> out,
  List<String> lines,
  int budget,
  String side,
  PreviewEntry Function(String) make,
) {
  if (budget <= 0 || lines.isEmpty) return;
  final shown = lines.length <= budget ? lines : lines.take(budget).toList();
  for (final l in shown) {
    out.add(make(l));
  }
  if (lines.length > budget) {
    final sign = side == 'added' ? '+' : '-';
    out.add(PreviewContext(
        '… ($sign${lines.length - budget} more $side)'));
  }
}

Future<List<PreviewEntry>> _writePreview(Map<String, dynamic> input) async {
  final path = input['filePath'] as String? ?? '(no path)';
  final content = input['content'] as String? ?? '';
  final newLines = const LineSplitter().convert(content);
  final file = File(path);
  final exists = await file.exists();

  if (!exists) {
    return [
      PreviewHeader('write: $path (new file, ${content.length} bytes)'),
      ..._take(newLines, _maxPreviewLines).map(PreviewAdded.new),
      if (newLines.length > _maxPreviewLines)
        PreviewContext('… (${newLines.length - _maxPreviewLines} more lines)'),
    ];
  }

  String oldText;
  try {
    oldText = await file.readAsString();
  } on FileSystemException catch (e) {
    return [PreviewHeader('write: $path (overwrite; cannot read existing: $e)')];
  }
  if (oldText == content) {
    return [PreviewHeader('write: $path (no change)')];
  }
  final oldLines = const LineSplitter().convert(oldText);

  final header = 'write: $path '
      '(overwrite, ${oldText.length} → ${content.length} bytes)';
  if (oldLines.length > _maxDiffLineCount ||
      newLines.length > _maxDiffLineCount) {
    return [
      PreviewHeader(header),
      PreviewContext(
          'file too large for inline diff (${oldLines.length} → ${newLines.length} lines)'),
    ];
  }
  final hunks = _hunks(_lineDiff(oldLines, newLines));
  return [PreviewHeader(header), ..._renderHunks(hunks)];
}

Iterable<String> _take(List<String> xs, int n) =>
    xs.length <= n ? xs : xs.take(n);

// --- diff plumbing ---------------------------------------------------------

class _DiffOp {
  final String mark; // ' ', '-', '+'
  final String line;
  const _DiffOp(this.mark, this.line);
}

/// Classic LCS line diff. Returns ops in original order: ` ` (context),
/// `-` (removed from old), `+` (added in new). O(m*n) in both time and
/// memory; we cap inputs in [_writePreview] before getting here.
List<_DiffOp> _lineDiff(List<String> a, List<String> b) {
  final m = a.length;
  final n = b.length;
  // lcs[i][j] = length of LCS of a[0..i] and b[0..j].
  final lcs = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));
  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      if (a[i - 1] == b[j - 1]) {
        lcs[i][j] = lcs[i - 1][j - 1] + 1;
      } else {
        lcs[i][j] =
            lcs[i - 1][j] >= lcs[i][j - 1] ? lcs[i - 1][j] : lcs[i][j - 1];
      }
    }
  }
  final ops = <_DiffOp>[];
  var i = m, j = n;
  while (i > 0 && j > 0) {
    if (a[i - 1] == b[j - 1]) {
      ops.add(_DiffOp(' ', a[i - 1]));
      i--;
      j--;
    } else if (lcs[i - 1][j] >= lcs[i][j - 1]) {
      ops.add(_DiffOp('-', a[i - 1]));
      i--;
    } else {
      ops.add(_DiffOp('+', b[j - 1]));
      j--;
    }
  }
  while (i > 0) {
    ops.add(_DiffOp('-', a[--i]));
  }
  while (j > 0) {
    ops.add(_DiffOp('+', b[--j]));
  }
  return ops.reversed.toList();
}

/// Group ops into hunks: each hunk surrounds at least one change with up to
/// [contextLines] of context above and below. Pure context runs between
/// hunks are dropped.
List<List<_DiffOp>> _hunks(List<_DiffOp> ops, {int contextLines = 2}) {
  final hunks = <List<_DiffOp>>[];
  var current = <_DiffOp>[];
  var contextRun = 0;

  void flush() {
    if (current.isNotEmpty &&
        current.any((o) => o.mark == '+' || o.mark == '-')) {
      hunks.add(current);
    }
    current = <_DiffOp>[];
    contextRun = 0;
  }

  for (var idx = 0; idx < ops.length; idx++) {
    final op = ops[idx];
    if (op.mark == ' ') {
      // Look ahead: any change within contextLines? If yes, keep this row
      // as context. Otherwise, close the current hunk.
      var changeNearby = false;
      for (var k = idx; k < ops.length && k < idx + contextLines + 1; k++) {
        if (ops[k].mark != ' ') {
          changeNearby = true;
          break;
        }
      }
      final hasOpenChange =
          current.any((o) => o.mark == '+' || o.mark == '-');
      if (hasOpenChange && contextRun < contextLines) {
        current.add(op);
        contextRun++;
      } else if (changeNearby) {
        current.add(op);
        contextRun = 0;
      } else if (hasOpenChange) {
        flush();
      }
    } else {
      current.add(op);
      contextRun = 0;
    }
  }
  flush();
  return hunks;
}

List<PreviewEntry> _renderHunks(List<List<_DiffOp>> hunks) {
  final out = <PreviewEntry>[];
  var emitted = 0;
  for (var h = 0; h < hunks.length; h++) {
    if (h > 0) out.add(const PreviewSeparator());
    for (final op in hunks[h]) {
      if (emitted >= _maxPreviewLines) {
        out.add(const PreviewContext('… (more changes omitted)'));
        return out;
      }
      switch (op.mark) {
        case '+':
          out.add(PreviewAdded(op.line));
        case '-':
          out.add(PreviewRemoved(op.line));
        default:
          out.add(PreviewContext(op.line));
      }
      emitted++;
    }
  }
  return out;
}
