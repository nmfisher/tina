import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// `killProcessTree` enumerates descendants via `pgrep` and signals each pid —
/// only meaningful on macOS/Linux. Skipped elsewhere.
final bool _supported = Platform.isMacOS || Platform.isLinux;

/// True when [pid] is a live process (`kill -0` succeeds). Zombies count as
/// dead on Linux: a container whose PID 1 never reaps orphans keeps SIGKILLed
/// children as zombies, which `kill -0` still reports as alive (#32).
Future<bool> _alive(int pid) async {
  if (await _zombie(pid)) return false;
  final r = await Process.run('kill', ['-0', '$pid']);
  return r.exitCode == 0;
}

/// True while [pid] sits in state `Z` in `/proc/<pid>/stat` (Linux only).
/// The comm field can contain spaces/parentheses, so the state is parsed as
/// the field right after the LAST ')'.
Future<bool> _zombie(int pid) async {
  if (!Platform.isLinux) return false;
  try {
    final stat = await File('/proc/$pid/stat').readAsString();
    final state = stat.substring(stat.lastIndexOf(')') + 1).trim();
    return state.startsWith('Z');
  } catch (_) {
    return false; // No /proc entry: not a zombie; let `kill -0` decide.
  }
}

/// Direct children of [pid] via `pgrep -P`.
Future<List<int>> _childrenOf(int pid) async {
  final r = await Process.run('pgrep', ['-P', '$pid']);
  if (r.exitCode != 0) return const [];
  final out = r.stdout;
  if (out is! String) return const [];
  return out
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .map(int.tryParse)
      .whereType<int>()
      .toList();
}

void main() {
  test('kills a backgrounded descendant that survives a bare kill of the root',
      () async {
    if (!_supported) return;
    // sh backgrounds two `sleep`s; a bare `Process.kill(sh)` would leave them
    // orphaned. killProcessTree must reap the whole tree.
    final proc = await Process.start(
      'sh',
      ['-c', 'sleep 30 & sleep 30 & wait'],
    );
    try {
      // Let the children start.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final children = await _childrenOf(proc.pid);
      expect(children.length, greaterThanOrEqualTo(2),
          reason: 'sh should have backgrounded sleep children');

      await killProcessTree(proc.pid, grace: const Duration(milliseconds: 800));

      // Every descendant and the root itself should be gone.
      for (final pid in children) {
        expect(await _alive(pid), isFalse,
            reason: 'descendant $pid should have been killed');
      }
      expect(await _alive(proc.pid), isFalse,
          reason: 'root sh should have been killed');
    } finally {
      // Best-effort cleanup if an assertion failed mid-test.
      await killProcessTree(proc.pid, grace: Duration.zero);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('is a safe no-op for an already-dead / bogus pid', () async {
    if (!_supported) return;
    // Should not throw.
    await killProcessTree(999999, grace: Duration.zero);
  });
}
