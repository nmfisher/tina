import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

final _log = Logger('tina.persistence');

/// A cross-process advisory lock guarding a single session directory.
///
/// Tina keeps all session state under `~/.tina/sessions/<id>/`. Two processes
/// that resume the *same* session would otherwise race on the shared
/// `<conversationId>.jsonl` (concurrent appends) and the manifest rewrites,
/// corrupting history. A [SessionLock] placed in the session directory
/// serializes access: the second process to start sees a [LockConflict] and
/// (by policy) refuses to proceed.
///
/// The lock is a `.lock` file written **atomically** (temp file + rename, the
/// same pattern as manifest/conversation writes), so a crash mid-acquire
/// leaves no half-written lock. Stale locks from crashed holders are reclaimed
/// via a PID-liveness check: if the recorded PID is no longer alive, the lock
/// is treated as free. `--force` overwrites a live lock regardless (use only
/// when you know the holder is gone but its lockfile lingers — e.g. after a
/// hard reboot that the liveness check can't detect).
///
/// This is advisory, not a hard filesystem lock — tina is a cooperative
/// single-user tool, not a database. It trades absolute safety for simplicity
/// and crash-recoverability.
class SessionLock {
  /// The session directory this lock guards.
  final Directory sessionDir;

  late final File lockFile = File('${sessionDir.path}${Platform.pathSeparator}.lock');

  bool _held = false;

  /// Whether this instance believes it holds the lock.
  bool get isHeld => _held;

  SessionLock(this.sessionDir);

  /// Try to take the lock. Returns `null` on success, or a [LockConflict]
  /// describing the live holder when the lock is taken and [force] is false.
  ///
  /// When [force] is true, an existing lock — live or stale — is overwritten
  /// (after logging) and acquisition succeeds.
  Future<LockConflict?> acquire({bool force = false}) async {
    if (_held) return null;

    if (await lockFile.exists()) {
      final existing = _read(lockFile);
      if (existing != null) {
        final alive = await _isProcessAlive(existing.pid);
        if (alive && !force) {
          return LockConflict(
            pid: existing.pid,
            hostname: existing.hostname,
            startedAt: existing.startedAt,
            sessionId: existing.sessionId,
          );
        }
        if (!alive) {
          _log.info('reclaiming stale session lock from dead pid '
              '${existing.pid} in ${sessionDir.path}');
        }
      }
      // Existing lock is stale/corrupt, or we're forcing — fall through and
      // overwrite it.
    }

    await _writeOurs();
    _held = true;
    return null;
  }

  /// Release the lock if held. Idempotent.
  Future<void> release() async {
    if (!_held) return;
    _held = false;
    try {
      if (await lockFile.exists()) await lockFile.delete();
    } catch (e) {
      _log.warning('failed to release session lock ${lockFile.path}', e);
    }
  }

  /// Synchronous release for crash/zone-guard paths that can't await. Best
  /// effort — deletes the lockfile directly. Idempotent.
  void releaseSync() {
    _held = false;
    try {
      lockFile.deleteSync();
    } catch (_) {
      // Already gone or unwritable — nothing more to do from a crash path.
    }
  }

  Future<void> _writeOurs() async {
    await sessionDir.create(recursive: true);
    final payload = jsonEncode({
      'pid': pid,
      'hostname': Platform.localHostname,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'sessionId': sessionDir.uri.pathSegments.last,
    });
    final tmp = File('${lockFile.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(lockFile.path);
  }

  _LockPayload? _read(File f) {
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final pidValue = j['pid'];
      if (pidValue is! int) return null;
      return _LockPayload(
        pid: pidValue,
        hostname: j['hostname'] as String?,
        startedAt: j['startedAt'] as String?,
        sessionId: j['sessionId'] as String?,
      );
    } catch (e) {
      _log.warning('session lock ${f.path} unreadable — treating as stale', e);
      return null;
    }
  }

  /// Whether [pid] is currently a live process. Cross-platform:
  /// POSIX uses `kill -0` (a non-zero exit is "no such process" unless it's a
  /// permission error, which still means the process exists); Windows uses
  /// `tasklist`. Unknown platforms assume alive (never clobber a real holder).
  static Future<bool> _isProcessAlive(int pid) async {
    if (Platform.isLinux || Platform.isMacOS) {
      final r = await Process.run('kill', ['-0', '$pid']);
      if (r.exitCode == 0) return true;
      // Non-zero exit is either "no such process" (dead) or EPERM (alive but
      // not ours). Distinguish via stderr so we don't mistake a live foreign
      // process for a dead one.
      final err = (r.stderr.toString()).toLowerCase();
      if (err.contains('operation not permitted') ||
          err.contains('permission denied')) {
        return true;
      }
      return false;
    }
    if (Platform.isWindows) {
      final r = await Process.run(
          'tasklist', ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']);
      return r.exitCode == 0 && r.stdout.toString().contains('$pid');
    }
    return true;
  }
}

/// The holder of a live lock, surfaced to the user when acquisition is refused.
class LockConflict {
  final int pid;
  final String? hostname;
  final String? startedAt;
  final String? sessionId;

  const LockConflict({
    required this.pid,
    this.hostname,
    this.startedAt,
    this.sessionId,
  });

  /// A user-facing message explaining the conflict and how to override.
  String toMessage() {
    final when = startedAt != null ? ' (started $startedAt)' : '';
    final where = (hostname != null && hostname!.isNotEmpty)
        ? ' on $hostname'
        : '';
    final which = (sessionId != null && sessionId!.isNotEmpty)
        ? ' session $sessionId'
        : '';
    return 'tina$which is already running in this session (pid $pid$where$when).\n'
        'Two processes on the same session corrupt its history. If the other '
        'process is gone, run with --force to take the lock.';
  }
}

class _LockPayload {
  final int pid;
  final String? hostname;
  final String? startedAt;
  final String? sessionId;
  const _LockPayload({
    required this.pid,
    this.hostname,
    this.startedAt,
    this.sessionId,
  });
}
