/// The portable enforcement boundary: the same operation × mode decision
/// route as the native sandbox ([SandboxedFileSystem]) with no `dart:io`
/// anywhere — a wasm composition root wraps its WASI filesystem in this
/// and the file tools get asks, grants and refusals again.
///
/// What stays native on purpose (stage-6 slice):
/// - **Canonicalization.** The native boundary resolves symlinks before
///   deciding (`resolveSymbolicLinks`); WASI preopen confinement already
///   refuses `..` and outside-preopen paths, so here the resolved path is
///   the normalized input and containment comes from the injected
///   [isWithinWorkspace] predicate (the composition root attributes the
///   path to a preopen; the workspace preopen is "inside").
/// - **The OS plan.** Protected-path denial is a plain prefix list
///   ([protectedPaths]); readable-path policy and the OS sandbox layout
///   do not exist under wasm.
///
/// The decision itself is shared code: [resolveAuthorization] (the one
/// total policy table), [operationReason] (the reason string the model
/// reads) and [FileGrants] (session grants) — the same bytes the native
/// boundary produces for the same question.
library;

import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:tina_mode/tina_mode.dart'
    show
        AccessCapability,
        AccessRequirement,
        AuthorizationRequest,
        AuthorizationRoute,
        PermissionMode,
        resolveAuthorization;

import 'file_system.dart';
import 'permissions.dart';
import 'sandbox_violation.dart';
import 'tool_boundary.dart';

/// A [FileSystem] decorator for platforms without `dart:io`: every tool
/// operation passes [guard] / [authorizeOperation], the mode table
/// allows or refuses, and an ask goes to the [Approver] exactly once per
/// operation — interior re-guards (atomic-write staging paths, missing
/// parent directories) are absorbed by the enclosing authorization.
final class AskingBoundary implements FileSystem, ToolBoundary {
  AskingBoundary(
    this._inner, {
    required String workspaceRoot,
    this.mode = PermissionMode.ask,
    this.approver,
    FileGrants? grants,
    List<String> protectedPaths = const [],
    bool Function(String path)? isWithinWorkspace,
  })  : _workspaceRoot = workspaceRoot,
        grants = grants ?? FileGrants(),
        _protected = List.unmodifiable(protectedPaths),
        _insideWorkspace = isWithinWorkspace ?? _defaultContainment(workspaceRoot);

  /// The underlying filesystem — WASI preopens under wasm, anything in
  /// tests.
  FileSystem _inner;

  /// The workspace root relative paths resolve against.
  String _workspaceRoot;

  /// The workspace root the boundary resolves against (read-only view;
  /// re-rooting is a native-only operation).
  String get workspaceRoot => _workspaceRoot;

  /// The containment answer for a resolved path: does it belong to the
  /// workspace? Callers wiring approval routing use this to shape the
  /// authorization request the mode policy re-resolves.
  bool isWithinWorkspacePath(String path) => _insideWorkspace(_resolve(path));

  /// The grant table that covers [op] (read grants are separate from
  /// write grants, exactly as in the native boundary).
  FileGrants grantsOf(FileOp op) => op == FileOp.read ? _readGrants : grants;

  /// The current permission mode; the owner keeps this in sync with the
  /// mode plugin (`modePolicy.listen`).
  PermissionMode mode;

  /// Who answers an ask. No approver means asks are refused (the same
  /// refusal the native boundary produces).
  Approver? approver;

  /// Session write grants ("always" answers). Read grants are separate,
  /// exactly as in the native boundary.
  FileGrants grants;

  /// Bumped by the owner when the policy changes; an in-flight
  /// authorization scope dies with its revision, as natively.
  int Function()? policyRevision;

  /// Mutation targets refused before the table is consulted (the config
  /// preopen, the workspace `.tina`).
  final List<String> _protected;

  /// Containment: which resolved paths belong to the workspace. The
  /// default is the trailing-separator prefix test the native table
  /// applies; a composition root with preopens passes preopen
  /// attribution instead.
  final bool Function(String path) _insideWorkspace;

  /// Temp staging paths of in-flight atomic writes, mapped to the target
  /// they stage for — the write of the temp and the rename onto the
  /// target share the target's authorization.
  final _temporaryTargets = <String, String>{};
  final _readGrants = FileGrants();

  static bool Function(String) _defaultContainment(String root) {
    final normalized = p.normalize(root);
    String trail(String path) => path.endsWith('/') ? path : '$path/';
    return (path) {
      final child = trail(p.normalize(path));
      final parent = trail(normalized);
      return child == parent || child.startsWith(parent);
    };
  }

  /// Resolve a tool-supplied path: workspace-relative join, normalize.
  /// No symlink walk exists here (see the library comment).
  String _resolve(String path) => p.normalize(
      p.isAbsolute(path) ? path : p.join(_workspaceRoot, path));

  bool _isProtected(String path) =>
      _protected.any((prefix) => _sameOrUnder(path, prefix));

  static bool _sameOrUnder(String child, String parent) {
    String trail(String path) => path.endsWith('/') ? path : '$path/';
    final c = trail(child);
    final par = trail(parent);
    return c == par || c.startsWith(par);
  }

  // ---- ToolBoundary ------------------------------------------------------

  @override
  Future<void> guard(FileOp op, String path) async {
    await _authorize(op, _resolve(path));
  }

  @override
  Future<T> authorizeOperation<T>(
      FileOp op, String path, Future<T> Function() body) async {
    final target = _resolve(path);
    await _authorize(op, target);
    final scope = _AuthorizationScope(
      this,
      op,
      target,
      Zone.current[_scopeKey] as _AuthorizationScope?,
      op == FileOp.write ? await _missingParents(target) : const <String>{},
    );
    try {
      return await runZoned(body, zoneValues: {_scopeKey: scope});
    } finally {
      scope.active = false;
    }
  }

  /// The parents of a write target that do not exist yet — creating them
  /// inside an authorized write must not ask again.
  Future<Set<String>> _missingParents(String target) async {
    final paths = <String>{};
    var parent = p.dirname(target);
    while (parent != p.dirname(parent) && !await _inner.directoryExists(parent)) {
      paths.add(parent);
      parent = p.dirname(parent);
    }
    return paths;
  }

  bool _scopeAllows(FileOp op, String target) {
    for (_AuthorizationScope? scope = Zone.current[_scopeKey]
        as _AuthorizationScope?;
        scope != null;
        scope = scope.parent) {
      if (scope.allows(this, op, target)) return true;
    }
    return false;
  }

  /// The one decision point, per call: protected-path refusal, then —
  /// with an approver wired — the same deference the native boundary
  /// shows a mounted policy: every operation is handed to the approver
  /// (the mode policy owns the table, precedents and the human ask),
  /// and a refusal throws [SandboxViolation] whose message is the reason
  /// the model will read. Without an approver the table decides here:
  /// an ask is refused ("no approver wired"), exactly as natively.
  Future<void> _authorize(FileOp op, String target) async {
    final staged = _temporaryTargets[target] ?? target;
    if (_scopeAllows(op, target) || staged != target && _scopeAllows(op, staged)) {
      return;
    }
    if (op == FileOp.write && _isProtected(staged)) {
      throw SandboxViolation(
          'write to a protected path is denied (${p.basename(staged)})');
    }
    final approver = this.approver;
    if (approver != null) {
      // The native boundary's `authorization` path: the reason is the
      // access line the mode policy re-derives its own ask wording from.
      final reason = 'Access to $staged';
      final approval = await approver((op: op, path: staged), reason);
      if (approval == Approval.no) {
        throw SandboxViolation('$reason — denied by the user');
      }
      if (approval == Approval.always) {
        (op == FileOp.read ? _readGrants : grants).rememberExact(staged);
      }
      return;
    }
    final resolution = resolveAuthorization(
      AuthorizationRequest(requirements: [
        AccessRequirement(
          op == FileOp.read ? AccessCapability.read : AccessCapability.write,
          staged,
          workspace: op == FileOp.read || _insideWorkspace(staged),
          granted: op == FileOp.read
              ? _readGrants.allows(staged)
              : grants.allows(staged),
        ),
      ]),
      mode,
    );
    switch (resolution.route) {
      case AuthorizationRoute.allow:
        return;
      case AuthorizationRoute.deny:
        throw SandboxViolation(resolution.reason);
      case AuthorizationRoute.human:
      case AuthorizationRoute.review:
        // The same reason strings the native boundary's table asks with:
        // reads that ask are outside-the-sandbox asks, writes carry the
        // operation reason.
        final reason = op == FileOp.read
            ? 'allow read outside the sandbox (${p.basename(staged)})?'
            : operationReason((op: op, path: staged), mode);
        throw SandboxViolation(
            '$reason — denied: no approver is wired to approve it');
    }
  }

  // ---- FileSystem --------------------------------------------------------

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
      return await _inner.delete(path);
    } finally {
      _temporaryTargets.remove(_resolve(path));
      _temporaryTargets.remove(path);
    }
  }

  @override
  Future<String> createTempFile({required String near}) async {
    // The temp lives in the same directory as `near`: authorize `near` as
    // a write (refusing staging outside every granted tree), then map the
    // temp path to that authorization so writing and renaming it does not
    // ask again. The mapping keys the resolved form — callers hand back
    // whatever string the inner filesystem returned.
    final approved = _resolve(near);
    await _authorize(FileOp.write, approved);
    final tmp = await _inner.createTempFile(near: near);
    _temporaryTargets[_resolve(tmp)] = approved;
    return tmp;
  }

  /// The zone value key for in-flight authorization scopes.
  static const _scopeKey = #askingBoundaryScope;
}

/// One authorized operation: the target plus the parents its write may
/// create, alive only for the body it wraps and only while the policy
/// revision it was decided under still stands.
final class _AuthorizationScope {
  _AuthorizationScope(
      this.boundary, this.op, this.target, this.parent, this.newParents)
      : revision = boundary.policyRevision?.call();
  final AskingBoundary boundary;
  final FileOp op;
  final String target;
  final _AuthorizationScope? parent;
  final Set<String> newParents;
  final int? revision;
  bool active = true;

  bool allows(AskingBoundary boundary, FileOp op, String target) {
    var matches = false;
    for (_AuthorizationScope? scope = this; scope != null; scope = scope.parent) {
      // A nested operation cannot extend the lifetime of an inherited grant.
      if (!scope.active ||
          scope.revision != scope.boundary.policyRevision?.call()) return false;
      if (identical(scope.boundary, boundary) &&
          (scope.op == op || scope.op == FileOp.write && op == FileOp.read) &&
          (scope.target == target || scope.newParents.contains(target))) {
        matches = true;
      }
    }
    return matches;
  }
}
