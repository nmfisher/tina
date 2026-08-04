import 'dart:io';

/// Kill [rootPid] together with every descendant in its process tree.
///
/// Why this exists: `Process.kill()` (and `RunningProcess.kill()`) signals only
/// the direct child, so a command that backgrounds or forks (`npm run dev &`,
/// a build server, a daemon) survives cancel/timeout/exit and leaks. macOS has
/// no `setsid`, so we can't drop the shell into its own process group and
/// `kill(-pgid)`; instead we enumerate the descendant tree with `pgrep -P`
/// (present on both macOS and Linux) and signal each pid. A double-forked
/// `setsid` daemon still escapes — the same known limitation pi has.
///
/// Sequence: SIGTERM every pid (descendants before the root), wait [grace] for a
/// clean exit, then SIGKILL whatever is still alive. All errors (already-dead
/// pids, missing `pgrep`, permission denied) are swallowed, so the function is
/// idempotent and safe on best-effort cleanup paths.
Future<void> killProcessTree(
  int rootPid, {
  Duration grace = const Duration(seconds: 2),
}) async {
  if (rootPid <= 0) return;
  final pids = await _descendantsOf(rootPid);
  if (!pids.contains(rootPid)) pids.add(rootPid);

  // SIGTERM descendants-first (deepest first), root last, so children don't get
  // re-parented to init and slip out of the tree.
  for (final pid in pids.reversed) {
    _signal(pid, ProcessSignal.sigterm);
  }
  if (grace > Duration.zero) {
    await Future<void>.delayed(grace);
  }
  // Force anything still alive.
  for (final pid in pids) {
    _signal(pid, ProcessSignal.sigkill);
  }
}

/// BFS over the process tree from [rootPid], returning every descendant pid
/// (root not included). Best-effort: returns an empty list if `pgrep` is missing
/// or fails.
Future<List<int>> _descendantsOf(int rootPid) async {
  final result = <int>[];
  final seen = <int>{rootPid};
  final queue = [rootPid];
  while (queue.isNotEmpty) {
    final parent = queue.removeAt(0);
    for (final child in await _childrenOf(parent)) {
      if (seen.add(child)) {
        result.add(child);
        queue.add(child);
      }
    }
  }
  return result;
}

/// Direct child pids of [pid] via `pgrep -P`, or an empty list on any failure.
Future<List<int>> _childrenOf(int pid) async {
  try {
    final res = await Process.run('pgrep', ['-P', '$pid']);
    if (res.exitCode != 0) return const [];
    final stdout = res.stdout;
    if (stdout is! String) return const [];
    return stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map(int.tryParse)
        .whereType<int>()
        .toList();
  } catch (_) {
    return const [];
  }
}

void _signal(int pid, ProcessSignal signal) {
  try {
    Process.killPid(pid, signal);
  } catch (_) {
    // Already dead, reaped, or not ours to signal — nothing to do.
  }
}
