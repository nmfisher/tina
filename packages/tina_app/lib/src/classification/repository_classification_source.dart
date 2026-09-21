import 'dart:convert';
import 'dart:io';

import 'package:file_tree/file_tree.dart' as tree;

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
  final bool skipHidden;
  RepositoryEvidenceReader({
    required this.root,
    required this.sandbox,
    this.policy,
    this.skipHidden = true,
    ProcessRunner processes = const IoProcessRunner(),
  }) : enumerator = GitFileEnumerator(
         processes: processes,
         maxFiles: 20000,
         maxOutputBytes: 2 * 1024 * 1024,
       );

  bool _eligible(String path) {
    if (!validProjectPath(path, root: false)) return false;
    final parts = path.toLowerCase().split('/');
    if (skipHidden && parts.any((part) => part.startsWith('.'))) return false;
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

  Future<tree.Snapshot> scan() => tree.scan(
    list: () async =>
        (await observe(EvidenceQuery(EvidenceKind.listing, '.'))).value
            as List<String>,
    maxFiles: 20000,
  );

  Future<EvidenceRead> observe(EvidenceQuery query) async {
    if (policy?.check(query.kind == EvidenceKind.file ? 'read' : 'glob', {
          'filePath': query.path,
        }) ==
        PermissionDecision.deny) {
      throw StateError('Evidence denied by permission policy');
    }
    await sandbox.validatePath(root);
    if (query.kind == EvidenceKind.listing) {
      // Leaf freshness checks list only that subtree, not the whole repository.
      final directory = p.join(root, query.path);
      await sandbox.validatePath(directory);
      final listing = await enumerator.enumerate(directory);
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
          .map((path) => query.path == '.' ? path : '${query.path}/$path')
          .where(
            (path) =>
                _eligible(path) &&
                insideScope(path, query.path) &&
                (!query.directOnly || tree.parent(path) == query.path) &&
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
    final bytes = await tree.readFile(
      root,
      query.path,
      validate: sandbox.validatePath,
    );
    if (bytes == null) return EvidenceRead(null);
    final text = utf8.decode(bytes);
    if (text.contains('\u0000'))
      throw StateError('Binary evidence is unsupported');
    return EvidenceRead(text);
  }
}
