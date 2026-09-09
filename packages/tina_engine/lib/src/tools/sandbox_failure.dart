import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/sandbox_access.dart';
import 'sandbox_runner.dart';
import 'tool.dart';
import 'tool_input.dart';

/// Evidence from a failed subprocess. This suggests an approval; it never
/// grants access or proves that replaying the command is safe.
class SandboxWriteFailure {
  final List<String> blockedPaths;
  final List<String> writablePaths;

  SandboxWriteFailure(Iterable<String> blocked, Iterable<String> writable)
      : blockedPaths = List.unmodifiable(blocked),
        writablePaths = List.unmodifiable(writable);

  String get explanation =>
      'The command failed with "Read-only file system" while writing:\n'
      '${blockedPaths.map((path) => '    $path').join('\n')}\n'
      'Those paths are outside the sandbox’s writable directories. '
      'The earlier command approval did not grant write access there.';

  String get recoveryInstructions => '$explanation\n'
      'Inspect possible partial effects before retrying. If replay is safe, '
      'submit the same command and cwd with retrySafety explaining what you '
      'checked and why retrying is safe. Tina will ask the user to approve '
      'the required directories: ${writablePaths.join(', ')}. '
      'Do not retry if the user denies access.';

  /// Only unambiguous absolute paths adjacent to an EROFS diagnostic qualify.
  /// "Permission denied" also describes ordinary ownership errors and is not
  /// enough evidence. Never select a broader ancestor for a missing parent.
  static SandboxWriteFailure? detect(
      String output, SandboxedProcessRunner runner) {
    final blocked = <String>{};
    final writable = <String>{};
    for (final line in output.split('\n')) {
      final marker = RegExp('read-only file system', caseSensitive: false)
          .firstMatch(line);
      if (marker == null) continue;
      final before = line.substring(0, marker.start).trimRight();
      final after = line.substring(marker.end).trim();
      final match =
          RegExp(r'''["'](/[^"'\r\n]+)["']:\s*$''').firstMatch(before) ??
              RegExp(r'''^:\s*["'](/[^"'\r\n]+)["']$''').firstMatch(after) ??
              RegExp(r'(?:^|: )(/[^:\r\n]+):\s*$').firstMatch(before) ??
              RegExp(r'cannot (?:create|open) (/[^:\r\n]+):\s*$')
                  .firstMatch(before);
      final path = match?.group(1);
      if (path == null || RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) continue;
      try {
        final directory = Directory(path).existsSync() ? path : p.dirname(path);
        final root = SandboxAccessPolicy.resolveRequestedPath(directory);
        if (runner.accessPolicy.allows(root)) continue;
        blocked.add(path);
        writable.add(root);
      } on ToolValidationException {
        // Keep generic diagnostics for ambiguous/missing directories.
      }
    }
    return writable.isEmpty ? null : SandboxWriteFailure(blocked, writable);
  }
}

/// Typed metadata stays separate from tool output, which is untrusted text.
class BashToolResult extends ToolResult {
  final SandboxWriteFailure? sandboxFailure;

  const BashToolResult(super.content,
      {super.isError,
      super.elapsed,
      super.timedOut,
      super.emptyOutput,
      this.sandboxFailure});
}
