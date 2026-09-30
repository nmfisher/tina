/// The OS-sandbox layout: which paths exist inside the confined child's
/// namespace (Linux `bwrap`) or are named in its Seatbelt profile (macOS
/// `sandbox-exec`). This is the kernel-side half of the writable-directories
/// contract: the gate ([WritableDirectories]) and the layout must be built
/// from **one** configuration, so a command the gate approves is never one
/// the kernel then refuses.
///
/// Host observations ([SandboxHostLayout.inspect]) are kept separate from
/// the pure builders, so tests can describe a machine without being it —
/// the same split the old engine used.
library;

import 'dart:io';

/// System directories the sandbox mounts read-only: the toolchain, visible
/// inside the namespace so compilers and interpreters keep working, but not
/// writable. Each is bound only when it exists on the host (bwrap fails on
/// a missing source).
///
/// Deliberately absent from the old engine's list: `/home`, `/mnt`,
/// `/media`, `/srv`, `/var`. The old sandbox mounted them read-only so
/// `$HOME` toolchains stayed visible; this port hides them instead — the
/// sandbox exists to keep a command away from the user's home and the rest
/// of the host, and `$HOME` is where the credentials live.
const List<String> kSandboxReadOnlyBinds = <String>[
  '/usr',
  '/bin',
  '/sbin',
  '/lib',
  '/lib64',
  '/etc',
  '/opt',
];

/// The temp directories a sandboxed command may write: its scratch space.
/// Resolved against [Platform.environment] so `TMPDIR` wins where set.
List<String> defaultSandboxTempDirs([Map<String, String>? environment]) {
  final tmp = environment?['TMPDIR'] ?? Platform.environment['TMPDIR'];
  return [
    if (tmp != null && tmp.isNotEmpty) tmp,
    '/tmp',
    '/var/tmp',
  ];
}

/// What the host looks like, as far as the sandbox cares: which of the
/// read-only candidates actually exist, where the temp directories are,
/// and where `/etc/resolv.conf` really points (so the resolver file can be
/// bound by its resolved name and the `/etc` symlink survives inside).
class SandboxHostLayout {
  final List<String> readOnlyDirectories;
  final List<String> temporaryDirectories;
  final String? resolverTarget;

  SandboxHostLayout({
    required Iterable<String> readOnlyDirectories,
    required Iterable<String> temporaryDirectories,
    this.resolverTarget,
  })  : readOnlyDirectories = List.unmodifiable(readOnlyDirectories),
        temporaryDirectories = List.unmodifiable(temporaryDirectories);

  /// Probe the running host. Read-only candidates are kept only when they
  /// exist; a missing source path would make bwrap fail outright.
  factory SandboxHostLayout.inspect({
    required Iterable<String> readOnlyDirectories,
    required Iterable<String> temporaryDirectories,
  }) {
    String? resolver;
    try {
      resolver = File('/etc/resolv.conf').resolveSymbolicLinksSync();
    } on FileSystemException {
      // Diagnostics then report no resolver configuration; never widen
      // access to all of /run to guess at a missing dependency.
    }
    return SandboxHostLayout(
      readOnlyDirectories:
          readOnlyDirectories.where((d) => Directory(d).existsSync()),
      temporaryDirectories: temporaryDirectories,
      resolverTarget: resolver,
    );
  }
}

/// The bwrap argv for one confinement: read-only system directories, the
/// resolver, temp scratch space, tina's data directory (visible, read-only),
/// the project root and any extra writable grants read-write, a fresh
/// `/dev` and `/proc`, a cleared environment rebuilt from
/// [childEnvironment], no network when [isolateNetwork], and — after `--` —
/// the command itself.
///
/// A PID namespace (`--unshare-pid`) makes the fresh `/proc` mean what it
/// looks like — only this command's processes — and stops a sandboxed
/// command from signalling the agent's own processes; bwrap reaps as pid 1
/// inside it, so the command's orphans are collected. `--die-with-parent`
/// means a sandboxed command cannot outlive the agent that started it.
List<String> buildBwrapArguments({
  required SandboxHostLayout host,
  required String workspaceRoot,
  String? tinaDir,
  required Iterable<String> writablePaths,
  required bool isolateNetwork,
  required Map<String, String> childEnvironment,
}) {
  final args = <String>['bwrap'];
  final bound = <String>{};

  void bind(String source, String target, {bool readOnly = false}) {
    if (source.isEmpty || target.isEmpty) return;
    if (!bound.add('$source->$target')) return;
    args
      ..add(readOnly ? '--ro-bind' : '--bind')
      ..add(source)
      ..add(target);
  }

  for (final dir in host.readOnlyDirectories) {
    bind(dir, dir, readOnly: true);
  }
  // Preserve the /etc symlink and expose only its resolved file. bwrap
  // creates destination parents without exposing their host contents.
  if (host.resolverTarget case final String resolver) {
    bind(resolver, resolver, readOnly: true);
  }
  for (final dir in host.temporaryDirectories) {
    bind(dir, dir);
  }
  if (tinaDir != null) bind(tinaDir, tinaDir, readOnly: true);
  bind(workspaceRoot, workspaceRoot);
  for (final path in writablePaths) {
    bind(path, path);
  }
  args
    ..add('--dev')
    ..add('/dev')
    ..add('--proc')
    ..add('/proc');
  // The child starts from a clean environment: only what the runner names
  // is passed through. The parent's environment — provider tokens among
  // them — stops here.
  args.add('--clearenv');
  for (final MapEntry(key: key, value: value) in childEnvironment.entries) {
    args
      ..add('--setenv')
      ..add(key)
      ..add(value);
  }
  args
    ..add('--unshare-pid')
    ..add('--die-with-parent');
  if (isolateNetwork) args.add('--unshare-net');
  args.add('--');
  return args;
}

/// Pure Seatbelt profile for `sandbox-exec -p`: everything is allowed
/// except the network (when [isolateNetwork]) and file writes — which are
/// re-granted per path below the deny, since a later allow overrides the
/// earlier deny for its subpaths.
///
/// When [hidePath] is set (the user's home), its reads are denied after the
/// blanket allow — and the paths the sandbox must keep reachable
/// ([readAllowPaths]) are re-allowed beneath it, so a project that lives
/// under the home keeps working while the rest of the home disappears.
String buildSeatbeltProfile({
  required Iterable<String> writablePaths,
  required bool isolateNetwork,
  String? hidePath,
  Iterable<String> readAllowPaths = const [],
}) {
  final sb = StringBuffer('(version 1)\n');
  sb.write('(allow default)\n'); // process, reads, everything not named below
  if (isolateNetwork) sb.write('(deny network*)\n');
  sb.write('(deny file-write*)\n'); // then deny every write, re-granting below
  // Programs such as git open /dev/null for output redirection. Grant only
  // data writes to that device, not metadata changes or access to all /dev.
  sb.write('(allow file-write-data (literal "/dev/null"))\n');
  if (hidePath != null) {
    sb.write('(deny file-read* (subpath "${_escapeProfilePath(hidePath)}"))\n');
    for (final path in readAllowPaths) {
      sb.write('(allow file-read* (subpath "${_escapeProfilePath(path)}"))\n');
    }
  }
  for (final path in writablePaths) {
    sb.write('(allow file-write* (subpath "${_escapeProfilePath(path)}"))\n');
  }
  return sb.toString();
}

String _escapeProfilePath(String s) =>
    s.replaceAll('\\', r'\\').replaceAll('"', r'\"');
