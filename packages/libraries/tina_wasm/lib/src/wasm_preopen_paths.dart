import 'dart:convert';

/// The preopened directories, as the host declared them.
final class WasmPreopenPaths<T> {
  WasmPreopenPaths(List<(T, String)> directories)
    : _directories = List.of(directories) {
    // Longest guest path first, so prefix resolution picks the deepest
    // match ('config/nested' over 'config').
    _directories.sort((a, b) => b.$2.length.compareTo(a.$2.length));
  }

  final List<(T, String)> _directories;

  /// The preopens as the host declared them: (descriptor, guest path).
  List<(T, String)> get directories => List.unmodifiable(_directories);

  /// The tool-facing view has no descriptors for host-managed state.
  WasmPreopenPaths<T> get workspaceOnly => WasmPreopenPaths<T>([
    for (final (descriptor, guest) in _directories)
      if (guest == '.' || guest.isEmpty) (descriptor, '.'),
  ]);

  String get configRoot =>
      _directories.any((directory) => directory.$2 == '/tina-config')
      ? '/tina-config'
      : _directories.any((directory) => directory.$2 == 'config')
      ? 'config'
      : '/tina-config';

  /// Additional host-managed paths that also have a spelling in the workspace.
  static List<String> protectedWorkspacePaths(Map<String, String> environment) {
    final encoded = environment['TINA_ENGINE_PROTECTED_PATHS'];
    if (encoded == null) return const [];
    return List<String>.from(jsonDecode(encoded) as List);
  }

  /// Resolves [path] against the preopens and returns the descriptor
  /// plus the remaining path under it, or null when [path] belongs to no
  /// preopen. Both 'config/settings.toml' and './config/settings.toml'
  /// resolve; absolute paths resolve when a preopen's guest path matches
  /// their prefix. Paths containing a `..` segment never resolve.
  (T, String)? resolve(String path) => _resolve(path);

  /// The guest path of the preopen [path] belongs to (the workspace is
  /// '.'), or null when no preopen owns it — the containment answer for
  /// permission boundaries: a path inside the workspace preopen is a
  /// workspace path, everything else is outside.
  String? guestRootOf(String path) => _locate(path)?.guest;

  (T, String)? _resolve(String path) {
    final location = _locate(path);
    return location == null ? null : (location.descriptor, location.relative);
  }

  ({T descriptor, String guest, String relative})? _locate(String path) {
    final segments = path.split('/');
    if (segments.contains('..') || path.contains('\u0000')) return null;
    final absolute = path.startsWith('/');
    final joined = segments
        .where((segment) => segment.isNotEmpty && segment != '.')
        .join('/');
    final candidate = absolute ? '/$joined' : joined;
    ({T descriptor, String guest, String relative})? workspace;
    for (final (descriptor, guestPath) in _directories) {
      if (!absolute && (guestPath == '.' || guestPath.isEmpty)) {
        workspace ??= (
          descriptor: descriptor,
          guest: '.',
          relative: candidate.isEmpty ? '.' : candidate,
        );
        continue;
      }
      if (absolute != guestPath.startsWith('/')) continue;
      if (candidate == guestPath)
        return (descriptor: descriptor, guest: guestPath, relative: '.');
      final root = guestPath.endsWith('/') ? guestPath : '$guestPath/';
      if (candidate.startsWith(root)) {
        return (
          descriptor: descriptor,
          guest: guestPath,
          relative: candidate.substring(root.length),
        );
      }
    }
    return workspace;
  }
}
