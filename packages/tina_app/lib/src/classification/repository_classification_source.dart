import 'dart:convert';
import 'dart:io';

import 'repository_evidence.dart';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

/// Observes the current working tree, including non-ignored untracked files.
/// Incomplete inventories and unreadable evidence fail rather than imply absence.
class RepositoryEvidenceReader {
  final String root;
  final SandboxedFileSystem sandbox;
  final GitFileEnumerator enumerator;
  final PermissionPolicy? policy;
  RepositoryEvidenceReader({
    required this.root,
    required this.sandbox,
    this.policy,
    ProcessRunner processes = const IoProcessRunner(),
  }) : enumerator = GitFileEnumerator(
         processes: processes,
         maxFiles: 20000,
         maxOutputBytes: 2 * 1024 * 1024,
       );

  bool _eligible(String path) {
    if (!validProjectPath(path, root: false)) return false;
    final parts = path.toLowerCase().split('/');
    if (parts.any(
      const {
        '.git',
        '.tina',
        'node_modules',
        'vendor',
        'build',
        'dist',
        '.dart_tool',
        '.gradle',
        '__pycache__',
      }.contains,
    ))
      return false;
    final name = parts.last;
    return name != '.env' &&
        !name.startsWith('.env.') &&
        name != '.npmrc' &&
        !name.endsWith('.pem') &&
        !name.endsWith('.key') &&
        !name.startsWith('credentials');
  }

  Future<void> _safe(String relative) async {
    await sandbox.validatePath(p.join(root, relative));
    var current = root;
    for (final part in relative.split('/')) {
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Evidence path contains a symlink');
      }
    }
  }

  Future<EvidenceRead> observe(EvidenceQuery query) async {
    if (policy?.check(query.kind == EvidenceKind.file ? 'read' : 'glob', {
          'filePath': query.path,
        }) ==
        PermissionDecision.deny) {
      throw StateError('Evidence denied by permission policy');
    }
    await sandbox.validatePath(root);
    if (query.kind == EvidenceKind.listing) {
      final listing = await enumerator.enumerate(root);
      if (listing.status != GitListingStatus.completed ||
          listing.gaps.isNotEmpty) {
        throw StateError(
          'A complete Git inventory is required for classification',
        );
      }
      // Git's cached listing includes tracked paths deleted in the working
      // tree. They must disappear from our inventory so filename-based and
      // negative classifications invalidate on deletion as well as addition.
      final candidates = listing.paths
          .where(
            (path) =>
                _eligible(path) &&
                insideScope(path, query.path) &&
                !query.excludedScopes.any((s) => insideScope(path, s)),
          )
          .toList();
      final paths = <String>[];
      for (var offset = 0; offset < candidates.length; offset += 32) {
        final batch = candidates.skip(offset).take(32).toList();
        final types = await Future.wait(
          batch.map(
            (path) =>
                FileSystemEntity.type(p.join(root, path), followLinks: false),
          ),
        );
        for (var i = 0; i < batch.length; i++) {
          if (types[i] == FileSystemEntityType.file) paths.add(batch[i]);
        }
      }
      return EvidenceRead(paths..sort());
    }
    if (!_eligible(query.path))
      throw StateError('Evidence path excluded by collection policy');
    await _safe(query.path);
    final file = File(p.join(root, query.path));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return EvidenceRead(null);
    if (type != FileSystemEntityType.file)
      throw StateError('Evidence must be a regular file');
    final before = await file.stat();
    const maxBytes = 128 * 1024;
    if (before.size > maxBytes)
      throw StateError('Evidence file exceeds 128 KiB');
    final handle = await file.open();
    try {
      final bytes = await handle.read(maxBytes + 1);
      final after = await file.stat();
      await _safe(query.path);
      if (bytes.length > maxBytes ||
          before.size != after.size ||
          before.modified != after.modified ||
          before.changed != after.changed) {
        throw StateError('Evidence changed or exceeded the read limit');
      }
      final text = utf8.decode(bytes);
      if (text.contains('\u0000'))
        throw StateError('Binary evidence is unsupported');
      return EvidenceRead(text);
    } finally {
      await handle.close();
    }
  }
}
