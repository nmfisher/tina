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

/// The bundle root directory (`<…>/bundle`) containing the running binary's
/// `bin/` + `lib/`, or null when the layout doesn't look like an extracted
/// release bundle (e.g. `dart run`, where resolvedExecutable is the VM).
String? bundleRootForCurrentProcess({String? resolvedExecutable}) {
  final exe = resolvedExecutable ?? Platform.resolvedExecutable;
  if (p.basename(exe) != 'tina') return null;
  final binDir = p.dirname(exe);
  if (p.basename(binDir) != 'bin') return null;
  final root = p.dirname(binDir);
  if (!File(p.join(binDir, 'tina')).existsSync()) return null;
  return root;
}

/// Downloads and installs [release] over the running installation.
///
/// Sequence: pick the platform asset → download to [workDir] (a temp scratch
/// dir) → verify the `*.sha256` asset when one exists → extract with system
/// `tar` → swap the bundle dir (old renamed to `<root>.old`, removed on a
/// later launch). [notice] receives progress lines for the chat stream.
///
/// The [bundleRootOverride] / [workDirOverride] / [archiveSupplier] seams
/// exist for tests; production calls take the defaults.
Future<UpdateResult> installRelease(
  ReleaseInfo release, {
  required void Function(String line) notice,
  http.Client? client,
  String? bundleRootOverride,
  String? workDirOverride,
  Future<File> Function()? archiveSupplier,
}) async {
  final target = targetForCurrentPlatform();
  final assetName = target == null ? null : 'tina-${release.tag}-$target.tar.gz';
  final assetUrl = assetName == null ? null : release.assetUrls[assetName];
  if (target == null || assetUrl == null) return UpdateResult.unsupported;

  final bundleRoot = bundleRootOverride ?? bundleRootForCurrentProcess();
  if (bundleRoot == null) return UpdateResult.manualRequired;

  final ownsClient = client == null;
  final http_ = client ?? http.Client();
  try {
    // 1. Download (or let the test supplier provide) the archive.
    final workDir = Directory(workDirOverride ??
        p.join(Directory.systemTemp.path, 'tina-update-${DateTime.now().microsecondsSinceEpoch}'));
    await workDir.create(recursive: true);
    final archive = await (archiveSupplier ??
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
        final expected = RegExp(r'^[0-9a-fA-F]{64}')
            .firstMatch(resp.body.trim())
            ?.group(0)
            ?.toLowerCase();
        final actual = await _sha256(archive);
        if (expected == null || actual == null || expected != actual) {
          throw UpdateError('checksum mismatch for $assetName');
        }
      } else {
        notice('checksum asset unreachable (HTTP ${resp.statusCode}); '
            'skipping verification');
      }
    }

    // 3. Extract. The tarball contains a top-level `bundle/` dir.
    final extracted = Directory(p.join(workDir.path, 'x'));
    await extracted.create(recursive: true);
    final tar = await Process.run(
        'tar', ['xzf', archive.absolute.path, '-C', extracted.path]);
    if (tar.exitCode != 0) {
      throw UpdateError('extraction failed: ${tar.stderr}');
    }
    final newBundle = Directory(p.join(extracted.path, 'bundle'));
    if (!File(p.join(newBundle.path, 'bin', 'tina')).existsSync()) {
      throw UpdateError('archive layout unexpected: no bundle/bin/tina');
    }

    // 4. Swap: rename the live bundle aside (open inodes keep the running
    // process alive), move the new one into place. Roll back on failure.
    return await _swapBundle(newBundle, Directory(bundleRoot), notice);
  } on UpdateError catch (e) {
    notice('update failed: ${e.message}');
    return UpdateResult.failed;
  } catch (e) {
    _log.fine('update failed', e);
    notice('update failed: $e');
    return UpdateResult.failed;
  } finally {
    if (ownsClient) http_.close();
  }
}

Future<UpdateResult> _swapBundle(
    Directory newBundle, Directory bundleRoot, void Function(String) notice) async {
  final old = Directory('${bundleRoot.path}.old');
  try {
    if (old.existsSync()) old.deleteSync(recursive: true);
    bundleRoot.renameSync(old.path);
  } catch (e) {
    throw UpdateError(
        'cannot move the current installation aside (read-only location?): $e');
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
  notice('installed ${p.basename(bundleRoot.path)} update — '
      'restart tina to finish');
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
      final hex = RegExp(r'^[0-9a-fA-F]{64}')
          .firstMatch((r.stdout as String).trim())
          ?.group(0);
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
    if (old.existsSync()) old.deleteSync(recursive: true);
  } catch (e) {
    _log.fine('stale .old bundle cleanup failed', e);
  }
}
