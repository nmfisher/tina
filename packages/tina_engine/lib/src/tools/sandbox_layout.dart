import 'dart:io';

/// Host observations are separate from the pure namespace builder. Tests can
/// describe distributions with /etc/resolv.conf symlinked into /run without
/// depending on the developer machine's resolver.
class SandboxHostLayout {
  final List<String> readOnlyDirectories;
  final List<String> temporaryDirectories;
  final String? resolverTarget;

  SandboxHostLayout(
      {required Iterable<String> readOnlyDirectories,
      required Iterable<String> temporaryDirectories,
      this.resolverTarget})
      : readOnlyDirectories = List.unmodifiable(readOnlyDirectories),
        temporaryDirectories = List.unmodifiable(temporaryDirectories);

  factory SandboxHostLayout.inspect(
      {required Iterable<String> readOnlyDirectories,
      required Iterable<String> temporaryDirectories}) {
    String? resolver;
    try {
      resolver = File('/etc/resolv.conf').resolveSymbolicLinksSync();
    } on FileSystemException {
      // Diagnostics report unavailable resolver configuration; never widen
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

/// No host probes here. Later mounts override earlier ones, so explicit
/// writable grants follow the base read-only namespace and project mount.
List<String> buildLinuxSandboxArguments(
    {required SandboxHostLayout host,
    required String? projectRoot,
    required Iterable<String> writablePaths,
    required bool readOnlyProject,
    required bool isolateNetwork}) {
  return [
    for (final dir in host.readOnlyDirectories) ...['--ro-bind', dir, dir],
    // Preserve the /etc symlink and expose only its resolved file. bwrap
    // creates destination parents without exposing their host contents.
    if (host.resolverTarget case final String resolver) ...[
      '--ro-bind',
      resolver,
      resolver
    ],
    for (final dir in host.temporaryDirectories) ...['--bind', dir, dir],
    if (projectRoot != null) ...[
      readOnlyProject ? '--ro-bind' : '--bind',
      projectRoot,
      projectRoot
    ],
    for (final dir in writablePaths) ...['--bind', dir, dir],
    '--dev', '/dev', '--proc', '/proc',
    if (isolateNetwork) '--unshare-net',
    '--',
  ];
}

/// Pure Seatbelt rendering over paths already resolved by host inspection.
String buildMacSandboxProfile(
    {required Iterable<String> writablePaths,
    required String? root,
    required bool readOnlyProject,
    required bool isolateNetwork}) {
  final sb = StringBuffer('(version 1)\n');
  sb.write('(allow default)\n'); // reads, network, process — unrestricted
  if (isolateNetwork) sb.write('(deny network*)\n');
  sb.write('(deny file-write*)\n'); // …then deny every write, re-granting below
  if (readOnlyProject) {
    sb.write('(deny file-read* (subpath "/Users"))\n');
    if (root != null) {
      sb.write('(allow file-read* (subpath "${_escapeProfilePath(root)}"))\n');
    }
  }
  for (final path in writablePaths) {
    sb.write('(allow file-write* (subpath "${_escapeProfilePath(path)}"))\n');
  }
  return sb.toString();
}

String _escapeProfilePath(String s) =>
    s.replaceAll('\\', r'\\').replaceAll('"', r'\"');
