import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_system.dart';
import 'permissions.dart';
import 'write_directories.dart';

/// Thrown by [SandboxedFileSystem] when an operation is refused. Tools catch
/// this and surface it verbatim via `ToolResult.error`; callers should not
/// need to handle it.
///
/// This is the refusal that reaches the model: [message] is the reason,
/// safe to show the user — it never includes the resolved real path of a
/// sensitive tree, only the path the tool passed in.
class SandboxViolation implements Exception {
  final String message;
  const SandboxViolation(this.message);

  @override
  String toString() => message;
}

/// A [FileSystem] decorator — the **enforcement boundary**.
///
/// No tool declares permissions and no guard sits in the loop: the model is
/// free to try any tool, and the thing that refuses is the filesystem the
/// tool was handed, resolved **per call**. Every read and write goes through
/// here, so one decorator covers every file operation; the refusal comes
/// back to the model as that call's tool result.
///
/// The decision is the operation × mode table ([decideOperation]):
///
/// - `ask` / `auto`: reads run; writes go to the mode-aware [approver].
/// - `allowEdits`: project writes run; other writes go to the [approver].
/// - `readOnly`: reads run; writes require explicit human approval.
///
/// Asking is fail-closed: no approver wired means deny. An approver's
/// [Approval.always] remembers a pattern in the session [grants], so
/// the second identical write does not ask again. A session grant
/// short-circuits the ask without consulting the approver.
///
/// Structural checks that need no mode and no table are kept verbatim, and
/// they apply to reads too: canonicalization resolves the project root and
/// every target to their real paths (so `../` and symlink escapes are
/// caught), the Tina data tree (`~/.tina/*`) is denied outright, and a
/// broken symlink is rejected because containment cannot be verified.
/// Tools whose walk cannot go through the seam (ls's listing, glob's
/// enumerate, stat) additionally assert their runtime `path` param via
/// [validatePath] in their own `execute()`.
class SandboxedFileSystem implements FileSystem {
  FileSystem _inner;
  String _projectRoot;
  String _tinaDir;

  /// The session permission mode. Mutable so a host can flip a live session
  /// (for example to [PermissionMode.readOnly] for a read-only run); each
  /// call reads whatever is current.
  PermissionMode mode;

  /// Who answers an out-of-project write. Null means asks deny — fail
  /// closed. The filesystem never blocks on the approver beyond this call.
  Approver? approver;

  /// The session's remembered "always" answers, as exact canonical paths. The approver's
  /// [Approval.always] causes a [remember] here; a host may also
  /// pre-seed grants to widen a grant deliberately.
  final FileGrants grants;
  WriteDirectories? writeDirectories;

  // Only temporary files created by this sandbox inherit the target grant.
  // This permits atomic replacement without approving unrelated siblings.
  final Map<String, String> _temporaryTargets = {};

  /// Zone-keyed authorizations granted for the duration of ONE tool
  /// operation. A tool operation consults the boundary once at its entry
  /// point (via ToolFileSystem.guard); the seam methods it then calls
  /// (writeFile, createTempFile, rename, delete behind an atomic write) each
  /// guard again internally — those re-entrances must recognize the decision
  /// already made for this operation instead of asking the approver over and
  /// over (six dialogs for one out-of-project write before this existed).
  ///
  /// A Dart [Zone] carries the grant, so concurrent tool operations on the
  /// same sandbox never see each other's authorizations, and an authorization
  /// cannot outlive the operation that earned it (unlike a bool field, which
  /// would leak across interleaved async operations).
  static final Object _authorizedOps = Object();

  /// Runs [body] with [op] at the canonical [path] pre-authorized: any
  /// [guard] with the same operation and resolved target inside [body] —
  /// however deeply nested through the seam — is a no-op. Structural checks
  /// still run on every interior guard; only the table/approver step is
  /// skipped, and only for the exact authorized target.
  ///
  /// The one decision for the operation is made HERE, before the zone
  /// exists: [authorize] runs the same structural + table/approver path any
  /// bare [guard] would, so an ask still reaches the [approver] exactly once
  /// and a refusal throws before [body] starts. The zone then only carries
  /// bookkeeping for the seam's internal re-entrances.
  /// The one decision point for a single tool operation: the same path any
  /// bare [guard] takes — structural checks, then the operation × mode table
  /// ([decideOperation]) with the current [mode]. A [ToolVerdict.ask] goes
  /// to the [approver] exactly once; a refusal throws [SandboxViolation].
  /// Does not authorize anything: pair with [authorizeOperation] when the
  /// operation continues through the seam's internally-guarded methods.
  Future<void> authorize(FileOp op, String path) => guard(op, path);

  Future<T> authorizeOperation<T>(
      FileOp op, String path, Future<T> Function() body) async {
    // The decision happens once, here, zone-free: without this the zone
    // below would pre-authorize a target nobody ever decided on, and an
    // out-of-workspace write would run without the approver ever firing.
    await authorize(op, path);
    final target = await resolveCanonical(path);
    final existing = Zone.current[_authorizedOps];
    final ops = existing ?? _AuthorizedOps();
    ops.add(op, target);
    final result = await (existing != null
        ? body()
        : runZoned(body, zoneValues: {_authorizedOps: ops}));
    // The zone dies with body; the local mutation only matters when we
    // joined an enclosing scope.
    if (existing != null) ops.remove(op, target);
    return result;
  }

  Future<String>? _rootFuture;
  Future<String>? _tinaFuture;

  SandboxedFileSystem(
    this._inner, {
    required String workspaceRoot,
    required Directory tinaDir,
    this.mode = PermissionMode.ask,
    this.approver,
    FileGrants? grants,
  })  : _projectRoot = workspaceRoot,
        _tinaDir = tinaDir.path,
        grants = grants ?? FileGrants();

  /// The project root the boundary was built with. Structural checks
  /// ([validatePath], [assertWithinProject]) always use it; the session
  /// table uses it too, and [reRoot] re-points everything at once.
  String get projectRoot => _projectRoot;

  /// Swap the boundary to a different project root at runtime. Structural
  /// root caches are dropped so the next check re-resolves the new root.
  void reRoot(String workspaceRoot) {
    _projectRoot = workspaceRoot;
    _rootFuture = null;
  }

  /// Swap the underlying filesystem at runtime (seam for hosts that resolve
  /// the inner implementation late).
  void reinner(FileSystem inner) {
    _inner = inner;
  }

  /// The Tina data dir this boundary denies. Structural, so also [reRoot]ed
  /// only when a host genuinely moves it (rare); see [reTina].
  String get tinaDirPath => _tinaDir;

  /// Re-point the denied Tina data tree (see [reRoot]).
  void reTina(Directory tinaDir) {
    _tinaDir = tinaDir.path;
    _tinaFuture = null;
  }

  /// Real, symlink-resolved project root. Resolved lazily and cached.
  Future<String> get _realRoot =>
      _rootFuture ??= resolveCanonical(_projectRoot);

  /// Real, symlink-resolved Tina data dir. Resolved lazily and cached; if the
  /// dir doesn't exist yet, the walk-up resolves its existing ancestor (home)
  /// and re-joins the `/.tina` tail, so the tree is denied before it's ever
  /// created.
  Future<String> get _realTina => _tinaFuture ??= resolveCanonical(_tinaDir);

  @override
  Future<bool> fileExists(String path) => _inner.fileExists(path);

  @override
  Future<bool> directoryExists(String path) => _inner.directoryExists(path);

  @override
  Future<List<int>> readFileBytes(String path) async {
    await guard(FileOp.read, path);
    return _inner.readFileBytes(path);
  }

  @override
  Future<String> readFileString(String path) async {
    await guard(FileOp.read, path);
    return _inner.readFileString(path);
  }

  @override
  Future<void> writeFile(String path, String content) async {
    await guard(FileOp.write, path);
    return _inner.writeFile(path, content);
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    await guard(FileOp.write, path);
    return _inner.createDirectory(path, recursive: recursive);
  }

  @override
  Future<void> rename(String from, String to) async {
    await guard(FileOp.write, from);
    await guard(FileOp.write, to);
    return _inner.rename(from, to);
  }

  @override
  Future<void> delete(String path) async {
    await guard(FileOp.write, path);
    try {
      await _inner.delete(path);
    } finally {
      _temporaryTargets.remove(await resolveCanonical(path));
    }
  }

  @override
  Future<String> createTempFile({required String near}) async {
    // The temp lives in the same dir as `near`; guard `near` as a write so a
    // temp can't be staged outside the root / inside tina.
    await guard(FileOp.write, near);
    final tmp = await _inner.createTempFile(near: near);
    _temporaryTargets[await resolveCanonical(tmp)] =
        await resolveCanonical(near);
    return tmp;
  }

  /// The one decision point, per call: structural checks first (canonical
  /// resolution, Tina-tree denial, broken symlinks), then the operation ×
  /// mode table ([decideOperation]) with the current [mode]. A granted or
  /// allowed verdict passes; an ask goes to the [approver] — no approver, or a
  /// refusal, throws [SandboxViolation] whose message is the reason the
  /// model will read.
  ///
  /// Re-entrance within one authorized tool operation ([authorizeOperation])
  /// skips only the table/approver step for the authorized target; structural
  /// checks always run.
  Future<void> guard(FileOp op, String path) async {
    final target = await resolveCanonical(path);
    await assertOutsideTina(target);
    final approvedTarget = _temporaryTargets[target] ?? target;
    await assertOutsideTina(approvedTarget);
    final authorized = Zone.current[_authorizedOps];
    if (authorized != null && authorized.contains(op, approvedTarget)) {
      return;
    }
    if (op == FileOp.write &&
        writeDirectories?.allows(approvedTarget) == true) {
      return;
    }
    final request = (op: op, path: approvedTarget);
    final decision = decideOperation(
      request,
      mode,
      projectRoot: await _realRoot,
      grants: grants,
    );
    switch (decision.verdict) {
      case ToolVerdict.allow:
        return;
      case ToolVerdict.deny:
        throw SandboxViolation(decision.reason);
      case ToolVerdict.ask:
        final approver = this.approver;
        if (approver == null) {
          throw SandboxViolation('${decision.reason} — denied: no approver '
              'is wired to approve it');
        }
        switch (await approver(request, decision.reason)) {
          case Approval.yes:
            return;
          case Approval.always:
            grants.rememberExact(approvedTarget);
            return;
          case Approval.no:
            throw SandboxViolation('${decision.reason} — denied by the user');
        }
    }
  }

  /// Both structural checks, in order: must be within the project root AND
  /// must not land in the Tina tree. Either throws [SandboxViolation].
  ///
  /// The containment check for tools whose walk the seam can't cover (ls's
  /// listing, glob's enumerate, stat): those tools call this in their
  /// `Tool.execute` with the same [SandboxedFileSystem] they were handed.
  /// It is the pre-table part of [guard] — mode-free and ask-free by
  /// design, so a host using it directly keeps the old containment
  /// semantics exactly.
  Future<void> validatePath(String path) async {
    final target = await resolveCanonical(path);
    await assertWithinProject(target);
    await assertOutsideTina(target);
  }

  /// Rejects any real path not equal-to/under the real project root. Resolves
  /// the root lazily; a path that resolves outside it (via `../` or a symlink
  /// escape) throws.
  Future<void> assertWithinProject(String target) async {
    final root = await _realRoot;
    if (!_isUnder(target, root)) {
      throw SandboxViolation(
          'Path escapes the project root: ${p.basename(target)}');
    }
  }

  /// Rejects any real path under the real Tina data dir. A symlinked
  /// `~/.tina` is still protected because both sides are canonicalized.
  Future<void> assertOutsideTina(String target) async {
    final tina = await _realTina;
    if (_isUnder(target, tina)) {
      throw SandboxViolation(
          'Access to the Tina data tree is blocked: ${p.basename(target)}');
    }
  }
}

/// True when [child] is [parent] or lies under it, using normalized paths with
/// a trailing separator so `/foo` is not falsely "under" `/fo`.
bool _isUnder(String child, String parent) {
  final c = _withTrailing(p.normalize(child));
  final par = _withTrailing(p.normalize(parent));
  return c == par || c.startsWith(par);
}

String _withTrailing(String path) => path.endsWith('/') ? path : '$path/';

/// Resolve [path] to its real, absolute form with every symlink expanded — the
/// canonical path used for containment checks. Relative paths resolve against
/// the current directory.
///
/// For a path whose final components don't exist yet (a write target), we walk
/// up to the deepest existing ancestor, resolve *that*, and re-join the
/// non-existent tail — so `project/newdir/file` validates against the real
/// `project` root without throwing on the missing leaf. A valid symlink is
/// resolved to its target; a **broken** symlink throws [SandboxViolation] (no
/// resolvable target → containment can't be verified, so it's rejected).
Future<String> resolveCanonical(String path) async {
  final absolute = p.normalize(
    p.isAbsolute(path) ? path : p.join(Directory.current.path, path),
  );

  switch (FileSystemEntity.typeSync(absolute, followLinks: false)) {
    case FileSystemEntityType.link:
      // Symlink — valid or broken. resolveSymbolicLinks follows to the target;
      // throws FileSystemException if the link is broken.
      try {
        return await File(absolute).resolveSymbolicLinks();
      } on FileSystemException {
        throw SandboxViolation(
            'Broken symlink cannot be verified: ${p.basename(path)}');
      }
    case FileSystemEntityType.notFound:
      // Non-existent, non-link: walk up to the deepest existing ancestor,
      // resolve it, and re-join the missing tail.
      var cursor = absolute;
      while (FileSystemEntity.typeSync(cursor, followLinks: true) ==
          FileSystemEntityType.notFound) {
        final parent = p.dirname(cursor);
        if (parent == cursor) break; // filesystem root
        cursor = parent;
      }
      final realAncestor = await _resolveExisting(cursor);
      if (cursor.length == absolute.length) return realAncestor;
      return realAncestor + absolute.substring(cursor.length);
    default:
      // Existing file or directory: resolve directly.
      return _resolveExisting(absolute);
  }
}

/// Resolve an existing file or directory to its real path, dispatching on type
/// so we call the right `resolveSymbolicLinks`. Returns the path unchanged if
/// it somehow doesn't exist (shouldn't happen given the caller's guard).
Future<String> _resolveExisting(String path) async {
  // Resolve the REAL type (following links) so a symlinked ancestor is
  // resolved to its target, not returned unresolved.
  switch (FileSystemEntity.typeSync(path, followLinks: true)) {
    case FileSystemEntityType.directory:
      return Directory(path).resolveSymbolicLinks();
    case FileSystemEntityType.file:
      return File(path).resolveSymbolicLinks();
    default:
      // Broken link or raced-away path: containment can't be verified.
      throw SandboxViolation(
          'Broken or missing path cannot be verified: ${p.basename(path)}');
  }
}

/// The (operation, canonical target) pairs authorized for one in-flight tool
/// operation. Mutable because [SandboxedFileSystem.authorizeOperation] joins
/// an enclosing scope when tools nest; the zone scoping keeps concurrent
/// operations isolated.
final class _AuthorizedOps {
  final Map<FileOp, Set<String>> _ops = {};

  void add(FileOp op, String target) {
    (_ops[op] ??= {}).add(target);
  }

  void remove(FileOp op, String target) {
    _ops[op]?.remove(target);
  }

  bool contains(FileOp op, String target) =>
      _ops[op]?.contains(target) ?? false;
}
