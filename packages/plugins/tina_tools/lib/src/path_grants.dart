import 'dart:convert';
import 'dart:io';

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

/// One workspace-owned permission file. Only human approvals write here.
final class PathGrants {
  PathGrants({this.file}) {
    reload();
  }
  final File? file;
  final List<PathGrant> _session = [];
  List<PathGrant> _saved = [];
  String? error;

  List<PathGrant> get grants {
    reload();
    return List.unmodifiable([..._saved, ..._session]);
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
    reload();
    final canonical = canonicalSandboxPath(path);
    final grant = PathGrant(canonical, write: write, recursive: recursive);
    if (persist && file != null) {
      // Never replace a damaged file with a partial grant set.
      if (error != null) throw FormatException(error!);
      final next = [
        ..._saved.where((g) => !(g.path == canonical &&
            g.recursive == recursive &&
            (!g.write || write))),
        grant
      ];
      file!.parent.createSync(recursive: true);
      final temporary = File('${file!.path}.tmp');
      temporary.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert({
                'version': 1,
                'grants': next.map((g) => g.toJson()).toList(),
              })}\n',
          flush: true);
      temporary.renameSync(file!.path);
      _saved = next;
    } else {
      _session.add(grant);
    }
  }

  void revoke(String path, {required bool write, required bool recursive}) {
    reload();
    if (error != null) throw FormatException(error!);
    bool matches(PathGrant g) =>
        g.path == path && g.write == write && g.recursive == recursive;
    _session.removeWhere(matches);
    _saved.removeWhere(matches);
    if (file == null) return;
    final temporary = File('${file!.path}.tmp');
    temporary.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({
              'version': 1,
              'grants': _saved.map((g) => g.toJson()).toList(),
            })}\n',
        flush: true);
    temporary.renameSync(file!.path);
  }
}
