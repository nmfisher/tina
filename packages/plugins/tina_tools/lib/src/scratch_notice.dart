import 'package:path/path.dart' as p;

/// The warning appended to tool results whose write target is session
/// scratch. The sandbox home and its `tmp/` are deleted when the session
/// ends (or when an abandoned home is reaped); a file there cannot be a
/// deliverable.
const scratchNotice =
    'Note: this location is session scratch under the sandbox home or '
    'TMPDIR. It is deleted when the session ends and cannot be relied on '
    'later. Deliverables belong in the workspace (e.g. .plans/ at the '
    'workspace root) or another durable location the user chose; '
    'short-lived intermediates are fine here.';

/// True when [path] lies under a session-scratch root: any sandbox home
/// generation under [sandboxHomesRoot], or [tmpdir] (the sandbox TMPDIR,
/// which already lives inside the home).
///
/// Comparison is path-lexical on normalized paths, matching how the home
/// layout is constructed: [sandboxHomesRoot] must be the canonical
/// `sandbox-homes` directory (no trailing slash), and subdirectories named
/// `session-<pid>-<random>` are generations. Paths under a workspace are
/// never scratch.
bool isSessionScratchPath(
  String path, {
  required String sandboxHomesRoot,
  required String tmpdir,
}) {
  bool under(String parent) {
    final c = p.normalize(path), r = p.normalize(parent);
    return p.equals(c, r) || p.isWithin(r, c);
  }

  if (under(tmpdir)) return true;
  if (!under(sandboxHomesRoot)) return false;
  final relative =
      p.relative(p.normalize(path), from: p.normalize(sandboxHomesRoot));
  final first = p.split(relative).first;
  return first.startsWith('session-');
}

/// The notice for [path] when it is session scratch, else null.
String? scratchPathNotice(
  String path, {
  required String sandboxHomesRoot,
  required String tmpdir,
}) =>
    isSessionScratchPath(path,
            sandboxHomesRoot: sandboxHomesRoot, tmpdir: tmpdir)
        ? scratchNotice
        : null;
