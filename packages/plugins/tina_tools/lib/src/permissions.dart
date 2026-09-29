/// The permission vocabulary for tina_tools.
///
/// The architecture (Nick's call): **no tool declares what it is allowed to
/// do.** The model is free to try any tool; the thing that refuses is the
/// [SandboxedFileSystem] the tool was handed, and the refusal comes back to
/// the model as that call's tool result. This file holds the words that
/// boundary needs: what was decided ([ToolVerdict]), under which session
/// mode ([PermissionMode]), about which operation ([FileOperation]).
///
/// The table ([decideOperation]) is total and pure — strings in, verdict
/// out. It never touches a terminal, a loop, or the real filesystem, so the
/// tests for it are headless by construction.
///
/// The rule that outlived the declarations: **read-only never asks** — a
/// write in [PermissionMode.readOnly] is denied outright, never put to the
/// user. And **asking is fail-closed**: no approver wired means deny.
library;

import 'package:tina_mode/tina_mode.dart';
export 'package:tina_mode/tina_mode.dart' show PermissionMode, ModeControl;

import 'glob.dart' show fileGlobMatch;

/// What was decided about one operation.
///
/// A [ToolVerdict.ask] is *not* an answer: whoever resolves it — the
/// filesystem's approver — decides, and no approver wired means deny.
enum ToolVerdict {
  /// Perform the operation.
  allow,

  /// Refuse it; the reason reaches the model as the tool result.
  deny,

  /// The approver decides. With no approver, this resolves to deny — fail closed.
  ask,
}

/// Which kind of operation the filesystem was asked to do.
enum FileOp {
  /// Read a path's bytes, contents, existence or listing.
  read,

  /// Create, overwrite, edit, move or delete something at a path.
  write,
}

/// One operation resolved by the filesystem, with the path it will act on —
/// canonical (symlinks resolved) by the time the filesystem consults the
/// table, so `../` and symlink escapes are judged on where they really land.
typedef FileOperation = ({FileOp op, String path});

/// Who answers an ask: a function from the request (and the reason it is
/// being asked) to one of three answers. A host wires a UI; nothing wired
/// means deny. Async, because the realistic approver shows a dialog and waits.
typedef Approver = Future<Approval> Function(
    FileOperation request, String reason);

/// What an approver may answer.
enum Approval {
  /// Run it this once; the next identical write asks again.
  yes,

  /// Run it and remember it for the session: the second identical write
  /// does not ask again. Remembered as a path glob by the caller.
  always,

  /// Refuse it.
  no,
}

/// The verdict plus the reason it is what it is. The reason is the string
/// the model eventually reads — a [SandboxViolation] message or a grant
/// note — so it names the axis that decided.
typedef FileDecision = ({ToolVerdict verdict, String reason});

/// Reads run in every mode; read-only denies writes before checking grants.
/// Allow-edits permits project writes. Other writes go through the mode
/// plugin's approval routing (human in ask, safety judge first in auto).
FileDecision decideOperation(
  FileOperation op,
  PermissionMode mode, {
  required String projectRoot,
  FileGrants? grants,
}) {
  if (op.op == FileOp.read) {
    return (
      verdict: ToolVerdict.allow,
      reason: 'reads are allowed anywhere but the Tina data tree',
    );
  }
  if (mode == PermissionMode.readOnly) {
    return (
      verdict: ToolVerdict.deny,
      reason: operationReason(op, mode),
    );
  }
  final granted = grants?.patternFor(op.path);
  if (granted != null) {
    return (
      verdict: ToolVerdict.allow,
      reason: 'allowed by session grant: $granted',
    );
  }
  if (mode == PermissionMode.allowEdits && _isUnder(op.path, projectRoot)) {
    return (
      verdict: ToolVerdict.allow,
      reason: 'write inside the project root',
    );
  }
  return (
    verdict: ToolVerdict.ask,
    reason: _isUnder(op.path, projectRoot)
        ? 'allow write in the project (${_leaf(op.path)})?'
        : operationReason(op, mode)
  );
}

/// Why the table said ask or deny, in one plain phrase — the string a UI
/// shows and the model reads. Never mentions a resolved sensitive path,
/// only the leaf name.
String operationReason(FileOperation op, PermissionMode mode) {
  final name = _leaf(op.path);
  return switch ((op.op, mode)) {
    (FileOp.read, _) => 'read of $name',
    (FileOp.write, PermissionMode.readOnly) =>
      'denied: writes are not permitted in read-only mode ($name)',
    (FileOp.write, _) => 'allow write outside the project root ($name)?',
  };
}

/// Session-scoped "always" answers, remembered as path globs.
///
/// An approver that says "always" causes the caller to [remember] a pattern;
/// the second identical write then matches and does not ask again. The
/// pattern the filesystem remembers is the canonical path itself — exact,
/// no wider than what was approved — but a host may [remember] any glob
/// (`/tmp/shared/**`) to widen a grant deliberately.
///
/// Sessions are in-memory by design: grants die with the object, so nothing
/// outlives the run that approved it.
final class FileGrants {
  final List<String> _patterns = [];

  /// The remembered patterns, oldest first. Unmodifiable view.
  List<String> get patterns => List.unmodifiable(_patterns);

  bool get isEmpty => _patterns.isEmpty;
  int get length => _patterns.length;

  /// Remembers [pattern] (a `fileGlobMatch` glob) and a dir-sibling `*`
  /// alongside it, so a grant on a directory (or on a file created via
  /// same-dir temp + rename) covers the directory itself and its siblings
  /// without covering any deeper tree.
  bool remember(String pattern) {
    if (_patterns.contains(pattern)) return false;
    _patterns.add(pattern);
    final slash = pattern.lastIndexOf('/');
    final dirGlob = slash < 0 ? '*' : '${pattern.substring(0, slash + 1)}*';
    if (dirGlob != pattern && !_patterns.contains(dirGlob)) {
      _patterns.add(dirGlob);
    }
    return true;
  }

  /// True when [path] matches any remembered pattern.
  bool allows(String path) => patternFor(path) != null;

  /// The first pattern that matches [path], or null.
  String? patternFor(String path) {
    for (final pattern in _patterns) {
      if (fileGlobMatch(pattern, path)) return pattern;
    }
    return null;
  }
}

/// True when [child] is [parent] or lies under it, using normalized paths
/// with a trailing separator so `/foo` is not falsely "under" `/fo`.
bool _isUnder(String child, String parent) {
  String trail(String path) => path.endsWith('/') ? path : '$path/';
  final c = trail(child == '' ? '/' : child);
  final par = trail(parent == '' ? '/' : parent);
  return c == par || c.startsWith(par);
}

/// The last path component — enough for a reason, never a resolved
/// sensitive tree.
String _leaf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final i = normalized.lastIndexOf('/');
  return i < 0 ? normalized : normalized.substring(i + 1);
}
