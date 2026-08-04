import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_system.dart';

/// Thrown by [SandboxedFileSystem] when a path escapes the project root or
/// lands inside the Tina data tree. Tools catch this and surface it verbatim
/// via [ToolResult.error] (same shape as [ToolValidationException]); callers
/// should not need to handle it.
///
/// [message] is safe to show the user — it never includes the resolved real
/// path of a sensitive tree, only the path the tool passed in.
class SandboxViolation implements Exception {
  final String message;
  const SandboxViolation(this.message);

  @override
  String toString() => message;
}

/// A [FileSystem] decorator that confines every read and write to a project
/// root and denies the Tina data tree (`~/.tina/*`).
///
/// This is the single enforcement point for path safety: because `read`/`edit`
/// `/`write` (and the fs-fallback path in `grep`/`glob`) all go through the
/// [FileSystem] interface, one decorator covers every reader/writer. The
/// `grep`/`glob` *subprocess* path (`rg path` / `fileEnumerator.enumerate`) can't
/// be covered here, so those tools additionally assert their runtime `path`
/// param in their own `execute()` (see the hardening plan §2).
///
/// Canonicalization resolves both the project root and every target to their
/// real, absolute paths via [resolveCanonical], so `../` *and* symlink escapes
/// (`project/link→/etc/passwd`) are caught. Non-existent write targets use a
/// walk-up algorithm so `project/newdir/file` validates against the real
/// `project` root without throwing on the missing leaf; broken symlinks are
/// rejected (no resolvable target → can't verify containment).
///
/// Constructed once at app composition and injected into tools through their
/// existing `fs` constructor parameter. Tests that inject [MemoryFileSystem]
/// directly simply don't get sandboxing (a test helper wraps one when needed).
class SandboxedFileSystem implements FileSystem {
  final FileSystem _inner;
  final String _projectRoot;
  final String _tinaDir;

  Future<String>? _rootFuture;
  Future<String>? _tinaFuture;

  SandboxedFileSystem(
    this._inner, {
    required String projectRoot,
    required Directory tinaDir,
  })  : _projectRoot = projectRoot,
        _tinaDir = tinaDir.path;

  /// Real, symlink-resolved project root. Resolved lazily and cached.
  Future<String> get _realRoot => _rootFuture ??= resolveCanonical(_projectRoot);

  /// Real, symlink-resolved Tina data dir. Resolved lazily and cached; if the
  /// dir doesn't exist yet, the walk-up resolves its existing ancestor (home)
  /// and re-joins the `/.tina` tail, so the tree is denied before it's ever
  /// created.
  Future<String> get _realTina =>
      _tinaFuture ??= resolveCanonical(_tinaDir);

  @override
  Future<bool> fileExists(String path) => _inner.fileExists(path);

  @override
  Future<bool> directoryExists(String path) => _inner.directoryExists(path);

  @override
  Future<List<int>> readFileBytes(String path) async {
    await validatePath(path);
    return _inner.readFileBytes(path);
  }

  @override
  Future<String> readFileString(String path) async {
    await validatePath(path);
    return _inner.readFileString(path);
  }

  @override
  Future<void> writeFile(String path, String content) async {
    await validatePath(path);
    return _inner.writeFile(path, content);
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    await validatePath(path);
    return _inner.createDirectory(path, recursive: recursive);
  }

  @override
  Future<void> rename(String from, String to) async {
    await validatePath(from);
    await validatePath(to);
    return _inner.rename(from, to);
  }

  @override
  Future<void> delete(String path) async {
    await validatePath(path);
    return _inner.delete(path);
  }

  @override
  Future<String> createTempFile({required String near}) async {
    // The temp lives in the same dir as `near`; validate `near` so a temp can't
    // be staged outside the root / inside tina.
    await validatePath(near);
    return _inner.createTempFile(near: near);
  }

  /// Both sandbox checks, in order: must be within the project root AND must
  /// not land in the Tina tree. Either throws [SandboxViolation].
  ///
  /// Public so tools whose *subprocess* path the seam can't cover (grep's `rg
  /// path`, glob's `fileEnumerator.enumerate(path)`) can assert their runtime
  /// `path` param directly in [Tool.execute]. Pass the same [SandboxedFileSystem]
  /// those tools get as their `fs`.
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

String _withTrailing(String path) =>
    path.endsWith('/') ? path : '$path/';

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
  // resolved to its target, not returned unresolved. The previous
  // followLinks:false dispatch left a symlinked directory ancestor
  // (project/escape -> /outside) unresolved, so a write to
  // project/escape/newfile passed containment and landed outside the root.
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
