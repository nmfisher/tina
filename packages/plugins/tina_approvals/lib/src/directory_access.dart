/// Human-selected directory access. The enforcement owner validates paths and
/// persists grants only after its invocation is still authorized and active.
/// All grants in one response use one explicitly selected scope.
enum DirectoryAccess { read, write }

enum DirectoryGrantScope { session, workspace, global }

final class DirectoryAccessGrant {
  const DirectoryAccessGrant(this.path, this.access, this.scope,
      {this.recursive = true});

  /// False grants exactly one file. True grants a directory subtree.
  final bool recursive;
  final String path;
  final DirectoryAccess access;
  final DirectoryGrantScope scope;
}
