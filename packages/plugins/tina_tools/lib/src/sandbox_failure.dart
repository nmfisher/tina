/// Why an OS-sandboxed command failed, told apart from an ordinary failed
/// command.
///
/// The distinction matters at the tool boundary: an ordinary non-zero exit
/// is a normal result the model reads and acts on, while a sandbox denial
/// means **the operating system stopped this exact invocation** — retrying
/// it unchanged inside the sandbox can never work. Ported from the old
/// engine's `sandbox_failure.dart`, narrowed to what this seam can decide:
/// evidence comes from the recorded [CommandCompleted] (exit code, stderr,
/// stdout) plus the layout, never from the live process tree.
///
/// Classification is deliberately narrow — unambiguous diagnostics only —
/// so a command that merely prints an old log, or fails for an ordinary
/// reason, is never reported as the sandbox's doing.
library;

import 'package:path/path.dart' as path;

import 'process_runner.dart';

/// Evidence that the sandbox, not the command, is why it failed.
sealed class SandboxDenial {
  const SandboxDenial();

  /// What happened, in the model's words. The first line the tool result
  /// shows.
  String get explanation;

  /// [explanation] plus the standing instruction: the gate may approve a
  /// wider run, but a denied retry inside the same jail is never authorized
  /// by this evidence.
  String get recoveryInstructions => '$explanation\n'
      'The operating system\'s sandbox prevented this command from completing. '
      'To request running this exact command outside the sandbox, call exec '
      'or bash with outside_sandbox: true and sandbox_reason explaining this '
      'failure. This requests separate human approval for host filesystem '
      'and network access. Ordinary execution approval does not grant this. '
      'Do not retry unchanged or switch shells as a workaround. Respect '
      'denied or cancelled approvals.';
}

/// A host file the subprocess namespace never made visible.
class PathHidden extends SandboxDenial {
  PathHidden(this.hiddenPaths);
  final List<String> hiddenPaths;
  @override
  String get explanation =>
      'These files exist on the host but are not mounted inside the Linux '
      'subprocess sandbox:\n${hiddenPaths.map((p) => '    $p').join('\n')}\n'
      'Built-in file tools inspect the host filesystem, so stat/read success '
      'does not prove a subprocess can access the same path.';
}

/// A write the kernel refused: the command reached a path outside the
/// sandbox's writable paths and the filesystem answered EROFS
/// ("Read-only file system").
class WriteDenied extends SandboxDenial {
  /// The unambiguous absolute paths the output blamed.
  final List<String> blockedPaths;

  /// The writable paths of the sandbox, for contrast in the explanation.
  final List<String> writablePaths;

  WriteDenied({
    required Iterable<String> blockedPaths,
    required Iterable<String> writablePaths,
  })  : blockedPaths = List.unmodifiable(blockedPaths),
        writablePaths = List.unmodifiable(writablePaths);

  @override
  String get explanation =>
      'The command failed with "Read-only file system" while writing:\n'
      '${blockedPaths.map((p) => '    $p').join('\n')}\n'
      'Those paths are outside the sandbox\'s writable paths:\n'
      '${writablePaths.map((p) => '    $p').join('\n')}\n'
      'The earlier command approval did not grant write access there.';
}

/// A write (or read) the kernel refused for a reason EROFS detection does
/// not cover — EACCES on a path the layout never mounted, for instance.
/// Deliberately blunter than [WriteDenied]: it names the paths it saw and
/// the sandbox, without claiming which rule was hit.
class OperationDenied extends SandboxDenial {
  final String diagnostic;

  /// The writable paths of the sandbox, named in the explanation.
  final List<String> writablePaths;

  OperationDenied(this.diagnostic, {required Iterable<String> writablePaths})
      : writablePaths = List.unmodifiable(writablePaths);

  @override
  String get explanation =>
      'The command failed with "$diagnostic" and the sandbox had not made '
      'that path reachable. Writable paths inside the sandbox:\n'
      '${writablePaths.map((p) => '    $p').join('\n')}\n'
      'The earlier command approval did not cover this.';
}

/// Classify one completed run. Returns the sandbox denial the output
/// evidences, or null when this reads as an ordinary failed command —
/// which is the common case and must stay unremarkable.
///
/// Only unambiguous diagnostics qualify:
///
/// - "Read-only file system" with an adjacent **absolute** path (EROFS on
///   a path the layout never made writable). "Permission denied" is not
///   enough evidence — it equally describes ordinary ownership errors —
///   and a missing writable root is classified by [sandboxedRun] before
///   this function is reached.
/// - "Operation not permitted" only when the layout never mounted a path
///   the output names (a bare EPERM from a program's own syscall is not
///   the sandbox's doing).
SandboxDenial? classifySandboxFailure(
  CommandCompleted completed, {
  required List<String> writablePaths,
  required List<String> mountedPaths,
  bool Function(String)? hostFileExists,
}) {
  if (completed.exitCode == 0 || completed.cancelled || completed.timedOut) {
    return null;
  }
  // ENOENT can also mean a genuinely absent file or dynamic loader. Only
  // name a hidden host path when existence and namespace exclusion agree.
  if (hostFileExists != null) {
    final hidden = <String>{};
    for (final line in completed.stderr.split('\n')) {
      if (!RegExp(r'(?:no such file or directory|not found)',
              caseSensitive: false)
          .hasMatch(line)) continue;
      final match = RegExp(
                  r'''["'](/[^"'\r\n]+)["']:\s*(?:[Nn]o such file or directory|not found)''')
              .firstMatch(line) ??
          RegExp(r'(?:execvp |: )(/[^:\r\n]+):\s*(?:[Nn]o such file or directory|not found)')
              .firstMatch(line);
      final p = match?.group(1);
      if (p != null &&
          !mountedPaths.any((m) => _under(p, m)) &&
          hostFileExists(p)) {
        hidden.add(p);
      }
    }
    if (hidden.isNotEmpty) return PathHidden(hidden.toList());
  }
  final output = '${completed.stderr}\n${completed.stdout}';
  final blocked = <String>{};
  final roots = <String>{};
  for (final line in output.split('\n')) {
    final marker =
        RegExp('read-only file system', caseSensitive: false).firstMatch(line);
    if (marker != null) {
      final before = line.substring(0, marker.start).trimRight();
      final after = line.substring(marker.end).trim();
      final match =
          RegExp(r'''["'](/[^"'\r\n]+)["']:\s*$''').firstMatch(before) ??
              RegExp(r'''^:\s*["'](/[^"'\r\n]+)["']$''').firstMatch(after) ??
              RegExp(r'(?:^|: )(/[^:\r\n]+):\s*$').firstMatch(before) ??
              RegExp(r'cannot (?:create|open) (/[^:\r\n]+):\s*$')
                  .firstMatch(before) ??
              // The shell's own form: `sh: can't create /etc/hosts:`
              RegExp(r'(?:^|\s)(/[\w./+-]+):\s*$').firstMatch(before);
      final p = match?.group(1);
      if (p == null || RegExp(r'[\x00-\x1f\x7f]').hasMatch(p)) continue;
      // A write inside the sandbox's own writable paths is the gate's
      // doing, not the kernel's: the command was approved for it. Only
      // paths the layout never made writable are evidence of a denial.
      final directory = path.dirname(p);
      if (writablePaths.any((w) => _under(directory, w))) continue;
      blocked.add(p);
      roots.add(directory);
    }
  }
  if (blocked.isNotEmpty) {
    return WriteDenied(
      blockedPaths: blocked.toList(),
      writablePaths: writablePaths,
    );
  }
  if (completed.exitCode != 0) {
    final eperm = RegExp(r'operation not permitted', caseSensitive: false)
        .firstMatch(output);
    if (eperm != null) {
      final named = RegExp(r"""/[^\s:,"']+""").allMatches(output).map((m) {
        var p = m.group(0)!;
        while (p.endsWith('.') || p.endsWith(':')) {
          p = p.substring(0, p.length - 1);
        }
        return p;
      }).toList();
      final unmounted =
          named.where((p) => !mountedPaths.any((m) => _under(p, m))).toSet();
      if (unmounted.isNotEmpty) {
        return OperationDenied(
          'Operation not permitted (${unmounted.join(', ')})',
          writablePaths: writablePaths,
        );
      }
    }
  }
  return null;
}

bool _under(String child, String parent) {
  final c = path.normalize(child);
  final p = path.normalize(parent);
  return path.equals(c, p) || path.isWithin(p, c);
}
