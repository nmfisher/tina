import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'sandbox_home.dart';

/// A human grant to one canonical file, or a directory and its descendants.
final class PathGrant {
  const PathGrant(this.path, {required this.write, required this.recursive});
  final String path;
  final bool write;
  final bool recursive;

  bool covers(String target, {bool write = false}) {
    if (write && !this.write) return false;
    // A replaced symlink must never redirect a saved grant.
    try {
      if (canonicalSandboxPath(path) != path) return false;
      if (!recursive && Directory(path).existsSync()) return false;
    } on FileSystemException {
      return false;
    }
    return target == path || recursive && p.isWithin(path, target);
  }

  Map<String, Object> toJson() => {
        'path': path,
        'access': write ? 'read-write' : 'read',
        'kind': recursive ? 'directory' : 'file',
      };
}

/// Private permissions for one workspace. Only human approvals write here.
final class PathGrants {
  PathGrants({this.file}) {
    reload();
  }

  factory PathGrants.forWorkspace(String workspace, Directory? directory) {
    final key = sha256.convert(utf8.encode(canonicalSandboxPath(workspace)));
    return PathGrants(
        file: directory == null ? null : File(p.join(directory.path, 'paths-$key.json')));
  }

  final File? file;
  bool Function(PathGrant grant)? permits;
  final List<PathGrant> _session = [];
  List<PathGrant> _saved = [];
  String? error;

  List<PathGrant> get grants {
    reload();
    return List.unmodifiable([..._saved, ..._session].where(_permits));
  }

  bool _permits(PathGrant grant) {
    try {
      return permits?.call(grant) ?? true;
    } on FileSystemException {
      return false;
    }
  }

  bool allows(String path, {bool write = false}) {
    try {
      final target = canonicalSandboxPath(path);
      return grants.any((grant) => grant.covers(target, write: write));
    } on FileSystemException {
      return false;
    }
  }

  void reload() {
    _saved = [];
    error = null;
    try {
      if (file == null || !file!.existsSync()) return;
      final document = jsonDecode(file!.readAsStringSync());
      if (document is! Map ||
          document['version'] != 1 ||
          document['grants'] is! List) {
        throw const FormatException('Expected version 1 and a grants list');
      }
      final parsed = <PathGrant>[];
      for (final entry in document['grants'] as List) {
        if (entry is! Map ||
            entry['path'] is! String ||
            !{'read', 'read-write'}.contains(entry['access']) ||
            !{'file', 'directory'}.contains(entry['kind'])) {
          throw const FormatException('Invalid path grant');
        }
        final path = entry['path'] as String;
        if (!p.isAbsolute(path) ||
            path.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
            p.normalize(path) != path) {
          throw const FormatException(
              'Grant paths must be canonical absolute paths');
        }
        parsed.add(PathGrant(path,
            write: entry['access'] == 'read-write',
            recursive: entry['kind'] == 'directory'));
      }
      _saved = parsed;
    } on Object catch (failure) {
      error = 'Cannot load path grants: $failure';
    }
  }

  void remember(String path,
      {required bool write, required bool recursive, bool persist = true}) {
    final canonical = canonicalSandboxPath(path);
    final grant = PathGrant(canonical, write: write, recursive: recursive);
    if (!_permits(grant)) {
      throw const FormatException('Path cannot be granted');
    }
    if (persist && file != null) {
      _update((saved) {
        saved.removeWhere((g) => g.path == canonical &&
            g.recursive == recursive &&
            (!g.write || write));
        saved.add(grant);
      });
    } else {
      _session.add(grant);
    }
  }

  void revoke(String path, {required bool write, required bool recursive}) {
    bool matches(PathGrant g) =>
        g.path == path && g.write == write && g.recursive == recursive;
    if (file?.existsSync() == true) _update((saved) => saved.removeWhere(matches));
    _session.removeWhere(matches);
  }

  void _update(void Function(List<PathGrant>) change) {
    final target = file!;
    target.parent.createSync(recursive: true);
    if (!Platform.isWindows &&
        Process.runSync('/bin/chmod', ['700', target.parent.path]).exitCode != 0) {
      throw FileSystemException('Cannot protect approval directory', target.parent.path);
    }
    final lock = File('${target.path}.lock').openSync(mode: FileMode.append);
    Directory? staging;
    try {
      lock.lockSync(FileLock.blockingExclusive);
      reload();
      if (error != null) throw FormatException(error!);
      final next = _saved.toList();
      change(next);
      staging = target.parent.createTempSync('.paths-');
      final temporary = File(p.join(staging.path, 'grants'));
      temporary.writeAsStringSync(jsonEncode({
        'version': 1,
        'grants': next.map((g) => g.toJson()).toList(),
      }), flush: true);
      if (!Platform.isWindows &&
          Process.runSync('/bin/chmod', ['600', temporary.path]).exitCode != 0) {
        throw FileSystemException('Cannot protect path grants', temporary.path);
      }
      temporary.renameSync(target.path);
      _saved = next;
    } finally {
      lock.closeSync();
      staging?.deleteSync(recursive: true);
    }
  }
}
