/// Workflow-name hygiene. Names become file names (`<name>.dot` under the
/// workflows dir) at every entry point — the editor's save-as, the
/// `/workflow` commands, and a `launch_workflow` tool call — so the guard
/// lives in one place instead of being re-derived (and drifting) at each.

/// True when [name] is safe to join into `<workflowsDir>/<name>.dot`: a
/// non-empty bare name with no path separators, no `..`, and no control
/// characters. A name like `../evil` would otherwise escape the workflows
/// dir.
bool isSafeWorkflowName(String name) {
  final n = name.trim();
  if (n.isEmpty) return false;
  if (n.contains('/') || n.contains('\\')) return false;
  if (n == '.' || n == '..' || n.contains('..')) return false;
  return !n.runes.any((r) => r < 0x20 || r == 0x7f);
}

/// Normalize user-typed input: trim, and drop a typed `.dot` suffix (the
/// caller appends it). Returns null when the result is empty or unsafe —
/// surface the reason from [nameRejection] in that case.
String? normalizeWorkflowName(String input) {
  var n = input.trim();
  if (n.toLowerCase().endsWith('.dot')) {
    n = n.substring(0, n.length - 4).trim();
  }
  return isSafeWorkflowName(n) ? n : null;
}

/// A human explanation for why [normalizeWorkflowName] rejected a name.
const String nameRejection = 'workflow names must be non-empty and may not '
    'contain "/", "\\", "..", or a typed ".dot" suffix';
