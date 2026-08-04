import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Serializes file-mutating operations ([EditTool], [WriteTool]) per file, across
/// *all* agents.
///
/// Edit and write are process-global singletons shared by every agent/sub-agent
/// (see `agent_pipeline.dart`), and [AgentQuota] permits several agents to run
/// concurrently. Without serialization, two agents editing the same file can
/// interleave their read-modify-write cycles and lose an update (or corrupt the
/// file). This lock chains same-file ops so they run one at a time; different
/// files still run concurrently.
///
/// The queue is keyed by the file's real path (symlinks resolved) so two paths
/// to the same inode collapse to one queue. A non-existent target (a brand-new
/// file) can't be resolved, so it falls back to the canonicalized path — stable
/// enough that two concurrent writes to the same new path still serialize.
class FileMutationLock {
  final Map<String, Future<void>> _queues = {};

  /// Run [action] once any prior same-file op has finished. The action's result
  /// (or thrown error) is propagated; the queue is released in `finally` so a
  /// failing op never stalls later ones.
  Future<R> withFileLock<R>(String path, Future<R> Function() action) async {
    final key = await _keyFor(path);
    // Read the current tail for this key and install our own future as the new
    // tail — atomically, since this runs synchronously up to `await prev` on the
    // single-threaded event loop.
    final prev = _queues[key] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[key] = done.future;
    try {
      await prev;
      return await action();
    } finally {
      done.complete();
      if (identical(_queues[key], done.future)) {
        _queues.remove(key);
      }
    }
  }

  Future<String> _keyFor(String path) async {
    try {
      return await File(path).resolveSymbolicLinks();
    } catch (_) {
      // Doesn't exist (new-file write) or unreadable symlink: fall back to a
      // canonicalized absolute path so the same path string still collides.
      return p.canonicalize(path);
    }
  }
}
