import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/sandbox_access.dart';
import 'sandbox_runner.dart';
import 'tool.dart';
import 'tool_input.dart';
import 'execution_diagnostic.dart';

/// Evidence from a failed subprocess that the sandbox is why it failed. This
/// suggests an approval; it never grants access or proves that replaying the
/// command is safe.
sealed class SandboxFailure {
  const SandboxFailure();

  /// Why the command failed, in the user's terms.
  String get explanation;

  String get recoveryInstructions => '$explanation\n'
      'Tina will ask the user separately whether to retry this exact command '
      'once outside the sandbox. Do not work around a denied retry.';
}

/// A write the sandbox refused: the command reached a path outside the
/// writable directories and the kernel said so.
class SandboxWriteFailure extends SandboxFailure {
  final List<String> blockedPaths;
  final List<String> writablePaths;

  SandboxWriteFailure(Iterable<String> blocked, Iterable<String> writable)
      : blockedPaths = List.unmodifiable(blocked),
        writablePaths = List.unmodifiable(writable);

  @override
  String get explanation =>
      'The command failed with "Read-only file system" while writing:\n'
      '${blockedPaths.map((path) => '    $path').join('\n')}\n'
      'Those paths are outside the sandbox’s writable directories. '
      'The earlier command approval did not grant write access there.';

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

/// A command that refused to run because a file it depends on appeared to be
/// owned by somebody else.
///
/// The Linux sandbox is a user namespace, and an unprivileged one maps only the
/// calling user: a file owned by root on the host appears inside to belong to
/// nobody (uid 65534). Tools that check who owns their own configuration then
/// refuse — OpenSSH is the one users meet, because it will not read a config it
/// does not believe root or the caller owns — and print a complaint about file
/// permissions that describes nothing about the machine the user is on. The
/// command never gets as far as the network.
///
/// This is deliberately narrow in what it will believe. A complaint has to name
/// a path, and that path has to exist and be readable here: a file we genuinely
/// cannot read is a permissions problem of its own, and not evidence about the
/// sandbox. What remains is a tool refusing a file it can read but does not
/// believe we own — which, for the mounted system paths the sandbox does expose,
/// means the id it was shown was not the id on the host.
class SandboxOwnershipFailure extends SandboxFailure {
  /// The files the tool refused to use, as it named them.
  final List<String> refusedPaths;

  SandboxOwnershipFailure(Iterable<String> paths)
      : refusedPaths = List.unmodifiable(paths);

  @override
  String get explanation =>
      'The command failed because a tool refused to use a file it believes '
      'somebody else owns:\n'
      '${refusedPaths.map((path) => '    $path').join('\n')}\n'
      'The file is readable from here, so this is not a permission we are '
      'missing. Inside the sandbox a root-owned file appears to belong to '
      'nobody, and tools that check the owner — OpenSSH is the usual one — '
      'refuse to trust it rather than run. Retrying outside the sandbox '
      'restores the real owner.';

  /// The uid an unmapped user namespace shows for root-owned files.
  static const _overflowUid = 65534;

  /// Complaints that name the file they refused. Kept to the tools whose
  /// phrasing has no other reading; anything vaguer produces no evidence.
  /// Each pattern's first group is the path, and `uidGroup` is set where the
  /// complaint also names the id it found, which is proof in itself.
  static final List<({RegExp pattern, int? uidGroup})> _complaints = [
    // OpenSSH, before it connects to anything. It names no id, so the path's
    // readability is what has to carry the argument.
    (
      pattern: RegExp(r'[Bb]ad owner or permissions on (/\S+)'),
      uidGroup: null
    ),
    // sudo names both the uid it found and the one it wanted.
    (
      pattern: RegExp(r'(\S+) is owned by uid (\d+), should be \d+'),
      uidGroup: 2
    ),
  ];

  /// [isReadable] defaults to the filesystem. Tests inject it to state the
  /// host's answer directly instead of depending on the machine's `/etc`.
  static SandboxOwnershipFailure? detect(String output,
      {bool Function(String path)? isReadable}) {
    final readable = isReadable ?? _readableHere;
    final refused = <String>{};
    for (final complaint in _complaints) {
      for (final match in complaint.pattern.allMatches(output)) {
        final path = match.group(1);
        if (path == null ||
            !path.startsWith('/') ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
          continue;
        }
        // A complaint that names an id only counts when it names the id an
        // unmapped root becomes. Anything else is somebody's real file.
        final uid = complaint.uidGroup;
        if (uid != null && match.group(uid) != '$_overflowUid') continue;
        if (readable(path)) refused.add(path);
      }
    }
    return refused.isEmpty ? null : SandboxOwnershipFailure(refused);
  }

  static bool _readableHere(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      return true;
    } on FileSystemException {
      return false;
    } finally {
      handle?.closeSync();
    }
  }
}

/// An SSH authentication failure where the sandbox is why no key could be
/// offered: the environment names an agent socket that does not exist inside
/// the sandbox's mount namespace (the host's `/run/user/<uid>/...` tree is
/// not mounted), so ssh had no identity to offer and the server refused
/// publickey auth.
///
/// Deliberately conservative: it only claims the failure when the output
/// shows an auth refusal AND `SSH_AUTH_SOCK` names a path that is absent
/// here. A socket that exists and is reachable means the credentials
/// themselves are bad — that is not tina's to fix, so no claim is made.
class SandboxAgentSocketFailure extends SandboxFailure {
  /// The agent socket path named by `SSH_AUTH_SOCK`.
  final String socketPath;

  SandboxAgentSocketFailure(this.socketPath);

  /// The directory a writablePaths grant should request — derived from the
  /// environment's socket path, never from the failing command's text.
  String get parentDirectory => p.dirname(socketPath);

  @override
  String get explanation =>
      'SSH reported "Permission denied (publickey)" and the environment\'s '
      'SSH_AUTH_SOCK ($socketPath) does not exist inside the sandbox — the '
      'host\'s agent socket is outside its mount namespace, so ssh had no '
      'key to offer. Retrying the same command inside the sandbox cannot '
      'succeed.';

  @override
  String get recoveryInstructions => '$explanation\n'
      'Either request write access to the socket\'s parent directory '
      '($parentDirectory) via writablePaths so the live agent becomes '
      'reachable, or run this exact command once outside the sandbox. '
      'Do not work around a denied retry.';

  /// [sshAuthSock] defaults to the live environment; [exists] to the
  /// filesystem. Tests inject both to state the host's answer directly.
  static SandboxAgentSocketFailure? detect(String output,
      {String? sshAuthSock, bool Function(String path)? exists}) {
    final sock = sshAuthSock ?? Platform.environment['SSH_AUTH_SOCK'];
    if (sock == null || sock.isEmpty) return null;
    if (!RegExp('permission denied (?:\\(publickey\\)|\\(password\\))',
            caseSensitive: false)
        .hasMatch(output)) {
      return null;
    }
    if (!sock.startsWith('/') || RegExp(r'[\x00-\x1f\x7f]').hasMatch(sock)) {
      return null; // relative or hostile path — no claim
    }
    final present = (exists ?? _existsHere)(sock);
    if (present) return null; // reachable agent → plain bad credentials
    return SandboxAgentSocketFailure(sock);
  }

  static bool _existsHere(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
}

/// A successful shell can print a nested failure or simply read an old log.
/// This warning is informational; it must never populate retry authorization.
const maskedSandboxWarning =
    'The shell exited 0, but its output contains a "Read-only file system" '
    'diagnostic. A nested command may have failed, or this may be an old log. '
    'Inspect the result before treating the operation as successful.';

/// Typed metadata stays separate from tool output, which is untrusted text.
class ProcessToolResult extends ToolResult {
  final int? exitCode;
  final bool cancelled;
  final bool shell;
  final List<ExecutionDiagnostic> diagnostics;
  final SandboxFailure? sandboxFailure;

  /// Suspected failure in output from a successful shell. Unlike
  /// [sandboxFailure], this is not evidence for the automatic retry context.
  final String? sandboxWarning;

  const ProcessToolResult(super.content,
      {super.isError,
      super.elapsed,
      super.timedOut,
      super.emptyOutput,
      this.exitCode,
      this.cancelled = false,
      this.shell = true,
      this.diagnostics = const [],
      this.sandboxFailure,
      this.sandboxWarning});
}
