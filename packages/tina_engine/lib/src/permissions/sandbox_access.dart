import 'dart:io';

import 'package:path/path.dart' as p;

import '../tools/tool_input.dart';

/// Canonical directories whose writable access requires an explicit answer.
class SandboxAccessRequest {
  final List<String> paths;
  final String reason;

  SandboxAccessRequest(Iterable<String> paths, this.reason)
      : paths = List.unmodifiable(paths);
}

/// Owned by a project tool scope and shared by its agents. Command permission
/// rules never modify these grants. Invocation copies keep once grants local.
class SandboxAccessPolicy {
  final Set<String> _grants = {};
  final Set<String> _implicit = {};
  final Set<String> _readOnly = {};

  SandboxAccessPolicy({
    Iterable<String> writablePaths = const [],
    Iterable<String> implicitWritablePaths = const [],
    Iterable<String> readOnlyPaths = const [],
  }) {
    for (final path in writablePaths) {
      final resolved = _existing(path);
      if (resolved != null) _grants.add(resolved);
    }
    for (final path in implicitWritablePaths) {
      final resolved = _existing(path);
      if (resolved != null) _implicit.add(resolved);
    }
    for (final path in readOnlyPaths) {
      final resolved = _existing(path);
      if (resolved != null) _readOnly.add(resolved);
    }
  }

  static String? _existing(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  static String resolveRequestedPath(String path) {
    if (!p.isAbsolute(path) || RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
      throw const ToolValidationException(
          'writablePaths must contain absolute directory paths without control characters.');
    }
    final resolved = _existing(path);
    if (resolved == null || !Directory(resolved).existsSync()) {
      throw ToolValidationException(
          'Writable directory does not exist: $path. Request an existing, narrowly scoped directory.');
    }
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(resolved)) {
      throw const ToolValidationException(
          'Writable directory resolves to a path with control characters.');
    }
    if (resolved == p.rootPrefix(resolved)) {
      throw const ToolValidationException(
          'Request a narrowly scoped writable directory, not the filesystem root.');
    }
    return resolved;
  }

  /// Fail closed if an approved directory disappeared or became a symlink to
  /// somewhere else while the prompt was open or between commands.
  static void validate(Iterable<String> paths) {
    for (final path in paths) {
      if (_existing(path) != path || !Directory(path).existsSync()) {
        throw ToolValidationException(
            'Approved writable directory changed: $path. Request access again.');
      }
    }
  }

  List<String> get writablePaths {
    // Caches can be removed during setup. Revoke stale grants rather than
    // blocking every later command in the session, or following a new target.
    _grants.removeWhere(
        (path) => _existing(path) != path || !Directory(path).existsSync());
    return List.unmodifiable(_grants);
  }

  bool allows(String path) {
    bool covers(String root) => path == root || p.isWithin(root, path);
    return writablePaths.any(covers) ||
        (!_readOnly.any(covers) && _implicit.any(covers));
  }

  void grantForSession(SandboxAccessRequest request) {
    validate(request.paths);
    _grants.addAll(request.paths);
  }

  SandboxAccessPolicy forInvocation(SandboxAccessRequest request) {
    validate(request.paths);
    return SandboxAccessPolicy(
      writablePaths: [...writablePaths, ...request.paths],
      implicitWritablePaths: _implicit,
      readOnlyPaths: _readOnly,
    );
  }
}
