import 'dart:ffi';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'release_checker.dart';

final _log = Logger('tina.self_update');

/// How an [installRelease] attempt ended. Callers map these to user-facing
/// messages; only [success] changed anything on disk.
enum UpdateResult {
  /// New bundle swapped into place — the user should restart tina.
  success,

  /// No asset matches this platform (or the running binary isn't a bundle
  /// install) — point the user at the Releases page.
  unsupported,

  /// We know there's an update but can't replace the installation (not a
  /// bundle install, unwritable location) — print manual instructions.
  manualRequired,

  /// Download/verify/extract failed midway; nothing changed (any half-swap
  /// was rolled back). [UpdateError.message] carries the reason.
  failed,
}

/// The failure detail accompanying [UpdateResult.failed].
class UpdateError implements Exception {
  UpdateError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The release asset target slug for the running platform, matching
/// tool/build_bundle.sh's matrix — or null where tina doesn't ship bundles.
String? targetForCurrentPlatform() {
  switch (Abi.current()) {
    case Abi.macosArm64:
      return 'macos-arm64';
    case Abi.linuxX64:
      return 'linux-x64';
    case Abi.linuxArm64:
      return 'linux-arm64';
    default:
      return null;
  }
}

/// Marker file present in a bundle root the updater may replace. A purely
/// structural `<root>/bin/tina` walk can land on a shared prefix like
/// `~/.local`; before the marker existed, an update renamed the whole
/// directory aside and the next launch swept it away — destroying everything
/// else installed there (v0.7.1, 2026-09-20). The marker plus the contents
/// check in [isOwnedBundleRoot] make a swap possible only into a directory
/// that exists exclusively for tina.
const bundleMarkerName = '.tina-bundle';

final _tinaLibEntry = RegExp(r'^lib(tina|notcurses)|^libsqlite3\.(so|dylib)$');

/// Whether [root] is a directory the updater owns outright: it carries
/// [bundleMarkerName], holds `bin/tina`, and contains nothing beyond tina's
/// own files — `bin/` with only `tina` in it, `lib/` with only tina and
/// notcurses/SQLite libraries, and dotfiles. Anything else (a shared prefix like
/// `~/.local`, foreign tools in `bin/`, a legacy unmarked install) fails
/// this check and must never be renamed, replaced, or deleted by the
/// updater.
bool isOwnedBundleRoot(String root) {
  FileSystemEntityType type(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false);
  try {
    if (type(root) != FileSystemEntityType.directory ||
        type(p.join(root, 'bin', 'tina')) != FileSystemEntityType.file ||
        type(p.join(root, bundleMarkerName)) != FileSystemEntityType.file) {
      return false;
    }
    for (final entry in Directory(root).listSync(followLinks: false)) {
      switch (p.basename(entry.path)) {
        case 'bin':
          if (entry is! Directory ||
              entry
                  .listSync(followLinks: false)
                  .any((e) => e is! File || p.basename(e.path) != 'tina')) {
            return false;
          }
        case 'lib':
          if (entry is! Directory ||
              entry
                  .listSync(followLinks: false)
                  .any(
                    (e) =>
                        e is! File ||
                        !_tinaLibEntry.hasMatch(p.basename(e.path)),
                  )) {
            return false;
          }
        default:
          if (entry is! File || !p.basename(entry.path).startsWith('.'))
            return false;
      }
    }
  } on FileSystemException {
    return false;
  }
  return true;
}

/// The structural bundle-root candidate for the running process
/// (`<root>/bin/tina` shape), without the ownership check —
/// [installRelease] layers ownership on top so an unowned candidate gets a
/// distinct, actionable refusal instead of a generic manualRequired.
String? bundleRootCandidateForCurrentProcess({String? resolvedExecutable}) {
  String exe;
  try {
    // The installed launcher lives in a shared bin directory. Resolve it to
    // the private bundle before deriving the root or checking ownership.
    exe = File(
      resolvedExecutable ?? Platform.resolvedExecutable,
    ).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
  if (p.basename(exe) != 'tina') return null;
  final binDir = p.dirname(exe);
  if (p.basename(binDir) != 'bin') return null;
  if (!File(p.join(binDir, 'tina')).existsSync()) return null;
  return p.dirname(binDir);
}

/// The bundle root the updater may replace: the running binary's
/// `<…>/bin/tina` layout — but only when that root is exclusively tina's
/// ([isOwnedBundleRoot]). Null when the layout doesn't look like an
/// extracted release bundle at all (e.g. `dart run`, where
/// resolvedExecutable is the VM), or when the candidate root is shared with
/// other tools' files.
String? bundleRootForCurrentProcess({String? resolvedExecutable}) {
  final candidate = bundleRootCandidateForCurrentProcess(
    resolvedExecutable: resolvedExecutable,
  );
  if (candidate == null || !isOwnedBundleRoot(candidate)) return null;
  return candidate;
}

/// Downloads and installs [release] over the running installation: thin
/// compose of [prepareUpdate] + [PreparedUpdate.install] for callers that
/// want one shot with no prompt in between.
Future<UpdateResult> installRelease(
  ReleaseInfo release, {
  required void Function(String line) notice,
  http.Client? client,
  String? bundleRootOverride,
  String? workDirOverride,
  Future<File> Function()? archiveSupplier,
}) async {
  final prepared = await prepareUpdate(
    release,
    notice: notice,
    client: client,
    bundleRootOverride: bundleRootOverride,
    workDirOverride: workDirOverride,
    archiveSupplier: archiveSupplier,
  );
  return switch (prepared) {
    UpdatePrepareUnsupported() => UpdateResult.unsupported,
    UpdatePrepareManualRequired() => UpdateResult.manualRequired,
    UpdatePrepareFailure() => UpdateResult.failed,
    UpdatePrepareReady ready => ready.update.install(notice: notice),
  };
}

/// How a [prepareUpdate] attempt ended. Only [UpdatePrepareReady] carries
/// something forward; the others logged their reason via `notice` already.
sealed class UpdatePrepareOutcome {
  const UpdatePrepareOutcome();
}

/// Download/verify/extract failed midway; nothing changed on disk.
class UpdatePrepareFailure extends UpdatePrepareOutcome {
  const UpdatePrepareFailure();
}

/// No asset matches this platform — point the user at the Releases page.
class UpdatePrepareUnsupported extends UpdatePrepareOutcome {
  const UpdatePrepareUnsupported();
}

/// Can't replace the installation (not a bundle install, unwritable or
/// unowned location) — the caller prints manual instructions.
class UpdatePrepareManualRequired extends UpdatePrepareOutcome {
  const UpdatePrepareManualRequired();
}

/// Ready to swap: the archive downloaded, checksum-verified, extracted, and
/// ownership-checked.
class UpdatePrepareReady extends UpdatePrepareOutcome {
  const UpdatePrepareReady(this.update);
  final PreparedUpdate update;
}

/// A downloaded, verified, extracted-but-not-installed update. `/update`
/// reaches this state before prompting, so a declined confirm costs nothing
/// and an accepted one starts at the swap.
class PreparedUpdate {
  PreparedUpdate._({
    required this.tag,
    required this.bundle,
    required this.bundleRoot,
    required this.workDir,
  });

  /// The release this update came from (e.g. `v0.8.18`).
  final String tag;

  /// The extracted new bundle (marker written, ownership-checked).
  final Directory bundle;

  /// The installation root this update would replace.
  final String bundleRoot;

  /// Scratch dir holding [bundle]; swept by [install]/[discard].
  final Directory workDir;

  /// Swap the new bundle into place over [bundleRoot] (old renamed to
  /// `<root>.old`, removed on a later launch). Only [UpdateResult.success]
  /// changed anything on disk; a failed swap is noticed and returns
  /// [UpdateResult.failed] after any rollback.
  Future<UpdateResult> install({
    required void Function(String line) notice,
  }) async {
    try {
      return await _swapBundle(bundle, Directory(bundleRoot), notice);
    } on UpdateError catch (e) {
      notice('update failed: ${e.message}');
      return UpdateResult.failed;
    } catch (e) {
      _log.fine('update failed', e);
      notice('update failed: $e');
      return UpdateResult.failed;
    }
  }

  /// Drop the update without touching the installation.
  void discard() {
    try {
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Downloads, verifies, and extracts [release] — everything up to (but not
/// including) the bundle swap.
///
/// Sequence: pick the platform asset → download to [workDir] (a temp scratch
/// dir) → verify the `*.sha256` asset when one exists → extract with system
/// `tar` → ownership-check the extracted bundle. [notice] receives progress
/// lines for the chat stream.
///
/// The [bundleRootOverride] / [workDirOverride] / [archiveSupplier] seams
/// exist for tests; production calls take the defaults.
Future<UpdatePrepareOutcome> prepareUpdate(
  ReleaseInfo release, {
  required void Function(String line) notice,
  http.Client? client,
  String? bundleRootOverride,
  String? workDirOverride,
  Future<File> Function()? archiveSupplier,
}) async {
  final target = targetForCurrentPlatform();
  final assetName = target == null
      ? null
      : 'tina-${release.tag}-$target.tar.gz';
  final assetUrl = assetName == null ? null : release.assetUrls[assetName];
  if (target == null || assetUrl == null) {
    return const UpdatePrepareUnsupported();
  }

  final candidate =
      bundleRootOverride ?? bundleRootCandidateForCurrentProcess();
  if (candidate == null) return const UpdatePrepareManualRequired();
  if (!isOwnedBundleRoot(candidate)) {
    notice(
      '$candidate is not an exclusively-tina directory (missing '
      '$bundleMarkerName, or it holds files that aren\'t tina\'s) — the '
      'updater will not replace it. Re-run the latest install.sh to migrate '
      'tina to a private bundle and enable /update.',
    );
    return const UpdatePrepareManualRequired();
  }
  final bundleRoot = candidate;

  final ownsClient = client == null;
  final http_ = client ?? http.Client();
  try {
    // 1. Download (or let the test supplier provide) the archive.
    final workDir = Directory(
      workDirOverride ??
          p.join(
            Directory.systemTemp.path,
            'tina-update-${DateTime.now().microsecondsSinceEpoch}',
          ),
    );
    await workDir.create(recursive: true);
    final archive =
        await (archiveSupplier ??
            () async {
              notice('downloading $assetName…');
              final resp = await http_.get(Uri.parse(assetUrl));
              if (resp.statusCode != 200) {
                throw UpdateError('download failed: HTTP ${resp.statusCode}');
              }
              final f = File(p.join(workDir.path, assetName));
              await f.writeAsBytes(resp.bodyBytes);
              return f;
            })();

    // 2. Verify SHA-256 when the release ships a checksum asset; a missing
    //    one (pre-checksum releases) passes with a warning.
    final checksumUrl = release.assetUrls['$assetName.sha256'];
    if (checksumUrl == null) {
      notice('no checksum asset for $assetName; skipping verification');
    } else {
      notice('verifying checksum…');
      final resp = await http_.get(Uri.parse(checksumUrl));
      if (resp.statusCode == 200) {
        final expected = RegExp(
          r'^[0-9a-fA-F]{64}',
        ).firstMatch(resp.body.trim())?.group(0)?.toLowerCase();
        final actual = await _sha256(archive);
        if (expected == null || actual == null || expected != actual) {
          throw UpdateError('checksum mismatch for $assetName');
        }
      } else {
        notice(
          'checksum asset unreachable (HTTP ${resp.statusCode}); '
          'skipping verification',
        );
      }
    }

    // 3. Extract. The tarball contains a top-level `bundle/` dir.
    final extracted = Directory(p.join(workDir.path, 'x'));
    await extracted.create(recursive: true);
    final tar = await Process.run('tar', [
      'xzf',
      archive.absolute.path,
      '-C',
      extracted.path,
    ]);
    if (tar.exitCode != 0) {
      throw UpdateError('extraction failed: ${tar.stderr}');
    }
    final newBundle = Directory(p.join(extracted.path, 'bundle'));
    if (!File(p.join(newBundle.path, 'bin', 'tina')).existsSync()) {
      throw UpdateError('archive layout unexpected: no bundle/bin/tina');
    }
    final marker = File(p.join(newBundle.path, bundleMarkerName));
    if (FileSystemEntity.isLinkSync(marker.path)) {
      throw UpdateError('archive layout unexpected: linked bundle marker');
    }
    marker.writeAsStringSync('tina bundle root\n');
    if (!isOwnedBundleRoot(newBundle.path)) {
      throw UpdateError('archive is not an exclusively-tina bundle');
    }

    // 4. Ready: everything is verified; the caller decides whether to swap.
    return UpdatePrepareReady(
      PreparedUpdate._(
        tag: release.tag,
        bundle: newBundle,
        bundleRoot: bundleRoot,
        workDir: workDir,
      ),
    );
  } on UpdateError catch (e) {
    notice('update failed: ${e.message}');
    return const UpdatePrepareFailure();
  } catch (e) {
    _log.fine('update failed', e);
    notice('update failed: $e');
    return const UpdatePrepareFailure();
  } finally {
    if (ownsClient) http_.close();
  }
}

Future<UpdateResult> _swapBundle(
  Directory newBundle,
  Directory bundleRoot,
  void Function(String) notice,
) async {
  final old = Directory('${bundleRoot.path}.old');
  // Belt and braces: the caller checked too, but re-verify at the moment of
  // the rename — a root that stopped looking exclusively tina's between
  // check and swap aborts here instead of being moved aside.
  if (!isOwnedBundleRoot(bundleRoot.path)) {
    throw UpdateError(
      '${bundleRoot.path} is not an exclusively-tina directory; refusing '
      'to swap it',
    );
  }
  try {
    if (old.existsSync()) {
      // A `<root>.old` left by anything else (another tool's backup
      // convention, a user's mv) is never ours to delete.
      if (!isOwnedBundleRoot(old.path)) {
        throw UpdateError(
          'a foreign ${old.path} exists; refusing to delete it — remove '
          'it by hand, then update again',
        );
      }
      old.deleteSync(recursive: true);
    }
    bundleRoot.renameSync(old.path);
  } on UpdateError {
    rethrow;
  } catch (e) {
    throw UpdateError(
      'cannot move the current installation aside (read-only location?): $e',
    );
  }
  try {
    _moveDir(newBundle, bundleRoot);
  } catch (e) {
    // Roll back so the install is no worse than before.
    try {
      if (bundleRoot.existsSync()) bundleRoot.deleteSync(recursive: true);
      old.renameSync(bundleRoot.path);
    } catch (_) {}
    throw UpdateError('moving the new bundle into place failed: $e');
  }
  notice(
    'installed ${p.basename(bundleRoot.path)} update — '
    'restart tina to finish',
  );
  return UpdateResult.success;
}

/// `Directory.rename` can't cross devices (the temp scratch dir may be on a
/// different volume than the install); fall back to a recursive copy + delete.
void _moveDir(Directory from, Directory to) {
  try {
    from.renameSync(to.path);
  } on FileSystemException {
    _copyDir(from, to);
    from.deleteSync(recursive: true);
  }
}

void _copyDir(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync()) {
    final dest = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      _copyDir(entity, Directory(dest));
    } else if (entity is File) {
      entity.copySync(dest);
    } else if (entity is Link) {
      Link(dest).createSync(entity.targetSync(), recursive: true);
    }
  }
}

/// SHA-256 via the system hasher (`shasum` on macOS, `sha256sum` on Linux) —
/// avoids a crypto dependency for one digest. Null when no hasher is available.
Future<String?> _sha256(File f) async {
  for (final cmd in const [
    ('shasum', ['a', '256']),
    ('sha256sum', <String>[]),
  ]) {
    final r = Process.runSync(cmd.$1, [...cmd.$2, f.absolute.path]);
    if (r.exitCode == 0) {
      final hex = RegExp(
        r'^[0-9a-fA-F]{64}',
      ).firstMatch((r.stdout as String).trim())?.group(0);
      if (hex != null) return hex.toLowerCase();
    }
  }
  return null;
}

/// Best-effort removal of a `<bundle>.old` left by a previous update. Called
/// on startup, a launch after the swap (the old bundle is only safe to delete
/// once no process is running from it — which a fresh launch guarantees for
/// the updater's process, and close enough for stragglers given it's
/// best-effort).
void cleanupStaleOldBundle({String? bundleRootOverride}) {
  try {
    final root = bundleRootOverride ?? bundleRootForCurrentProcess();
    if (root == null) return;
    final old = Directory('$root.old');
    if (!old.existsSync()) return;
    // Sweep only what an earlier tina update left behind. A `<root>.old`
    // created by anything else — another tool's backup convention, a user's
    // own mv — is never ours to delete.
    if (!isOwnedBundleRoot(old.path)) {
      _log.fine('leaving ${old.path} alone: not a tina bundle');
      return;
    }
    old.deleteSync(recursive: true);
  } catch (e) {
    _log.fine('stale .old bundle cleanup failed', e);
  }
}
