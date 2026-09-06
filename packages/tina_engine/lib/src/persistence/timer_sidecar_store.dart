/// Per-session timer sidecar store (§10 of docs/proposals/timer_system.md).
///
/// Each session's active timers serialize to `<session-id>.timers.json` in
/// the same directory as that session's transcript file. Schema is the spec's
/// version-1 shape (see [kTimerSidecarVersion]); unknown FIELDS inside
/// version 1 are ignored (forward-compat); an unknown VERSION is ignored
/// whole (with a notice); corrupt JSON reads as absent with a warning.
/// Writes are atomic (temp + rename, the recorder's `replace` pattern).
library;

import 'dart:convert';

import '../tools/atomic_write.dart' show atomicWriteFile;
import '../tools/file_system.dart';

/// The only sidecar version this code reads or writes (§10: version-1
/// schema, VERBATIM).
const int kTimerSidecarVersion = 1;

/// Where classification of a saved timer lands (§10 restore flow, step 2).
/// The classification itself is leg-2's job (the resume funnel owns the
/// warning/prompt texts); the store exposes only this vocabulary so both
/// legs speak the same words.
enum TimerSidecarClassification {
  /// `once && anchorEpochMs <= now` — expired while closed (warning + prune).
  expired,

  /// A `maxFires`/`once` timer whose fire count is used up (warning + prune).
  completed,

  /// Everything else: recurring always; a future one-off (ask to restore).
  restorable,
}

/// Reads and writes one session's `<session-id>.timers.json`. All I/O goes
/// through the injected [FileSystem] so tests run against a memory FS; pass
/// nothing (or `IoFileSystem`) for real disk.
class TimerSidecarStore {
  final FileSystem fs;

  const TimerSidecarStore([this.fs = const IoFileSystem()]);

  /// The sidecar path next to a session transcript: `<dir>/<session-id>.timers.json`.
  static String sidecarPathFor(String transcriptPath, String sessionId) {
    final slash = transcriptPath.lastIndexOf('/');
    final dir = slash < 0 ? '' : transcriptPath.substring(0, slash + 1);
    return '$dir$sessionId.timers.json';
  }

  /// Reads the saved records for [sessionId] whose transcript lives at
  /// [transcriptPath].
  ///
  /// Returns null when the sidecar is absent or unreadable-as-schema:
  /// - missing file → null, silent;
  /// - corrupt JSON → null with [onWarning];
  /// - unknown version → null with [onNotice] (the file is ignored whole and
  ///   left untouched);
  /// - version 1 → the timer list; unknown fields inside it are ignored, and
  ///   malformed entries are dropped.
  Future<List<Map<String, Object?>>?> read(
    String transcriptPath,
    String sessionId, {
    void Function(String message)? onWarning,
    void Function(String message)? onNotice,
  }) async {
    final path = sidecarPathFor(transcriptPath, sessionId);
    if (!await fs.fileExists(path)) return null;
    final String raw;
    try {
      raw = await fs.readFileString(path);
    } catch (e) {
      onWarning?.call(
        'timer sidecar for session $sessionId could not be read: $e',
      );
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      onWarning?.call(
        'timer sidecar for session $sessionId is corrupt (${e.message}) — '
        'ignoring it',
      );
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      onWarning?.call(
        'timer sidecar for session $sessionId is corrupt (not an object) — '
        'ignoring it',
      );
      return null;
    }
    final version = decoded['version'];
    if (version != kTimerSidecarVersion) {
      onNotice?.call(
        'timer sidecar for session $sessionId has unsupported version '
        '($version) — ignoring it',
      );
      return null;
    }
    final timers = decoded['timers'];
    if (timers == null) return const [];
    if (timers is! List) {
      onWarning?.call(
        'timer sidecar for session $sessionId has a malformed timers list — '
        'ignoring it',
      );
      return null;
    }
    return [
      for (final entry in timers)
        if (entry is Map<String, dynamic>)
          Map<String, Object?>.of(entry)
        else ...<Map<String, Object?>>[],
    ];
  }

  /// Atomically rewrites the sidecar with [timers]. When [timers] is empty
  /// the sidecar is deleted (no empty sidecars left on disk). The caller
  /// ensures the parent directory exists — the same expectation as the
  /// write tool, since the transcript beside it already does.
  Future<void> write(
    String transcriptPath,
    String sessionId,
    List<Map<String, Object?>> timers,
  ) async {
    final path = sidecarPathFor(transcriptPath, sessionId);
    if (timers.isEmpty) {
      if (await fs.fileExists(path)) await fs.delete(path);
      return;
    }
    final encoded = const JsonEncoder.withIndent('  ').convert({
      'version': kTimerSidecarVersion,
      'timers': timers,
    });
    await atomicWriteFile(fs, path, '$encoded\n');
  }
}
