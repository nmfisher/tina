import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:classifier/judgments.dart';
import 'package:classifier/exploration.dart';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

/// Git-aware bounded scan of fresh working-tree files. Git is used only to
/// enumerate names, with fixed arguments; no shell, hooks, builds, or writes.
/// Non-Git folders fail explicitly rather than silently ignoring ignore rules.
class RepositoryEvidenceSource implements ProjectEvidenceSource {
  final String root;
  final SandboxedFileSystem sandbox;
  final ProcessRunner processes;
  final int maxFiles;
  final int maxBytes;
  final int maxFileBytes;
  RepositoryEvidenceSource({
    required this.root,
    required this.sandbox,
    this.processes = const IoProcessRunner(),
    this.maxFiles = 5000,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxFileBytes = 1024 * 1024,
  }) {
    if (maxFiles <= 0 || maxBytes <= 0 || maxFileBytes <= 0) {
      throw ArgumentError('Evidence limits must be positive');
    }
  }

  @override
  Future<ProjectTree> enumerate(
    JudgmentCancellation cancellation,
    void Function(String) progress,
  ) async {
    if (cancellation.isCancelled)
      return ProjectTree([], ['Enumeration cancelled.']);
    await sandbox.validatePath(root);
    final gaps = <String>[];
    final names = await _files(cancellation, gaps);
    final eligible = names.where(_eligible).toList()..sort();
    final excluded = names.length - eligible.length;
    if (excluded > 0)
      gaps.add('$excluded paths excluded by collection policy.');
    return ProjectTree(eligible, gaps);
  }

  @override
  Future<EvidenceScan> read(
    List<String> paths,
    JudgmentCancellation cancellation,
    void Function(String) progress, {
    int? maxBytes,
  }) async {
    final byteLimit = maxBytes == null || maxBytes > this.maxBytes
        ? this.maxBytes
        : maxBytes;
    final gaps = <String>[];
    final evidence = <ProjectEvidence>[];
    final failures = <String, String>{};
    if (cancellation.isCancelled)
      return EvidenceScan([], 0, ['Reading cancelled.']);
    await sandbox.validatePath(root);
    final realRoot = await Directory(root).resolveSymbolicLinks();
    final names = paths.toSet().take(maxFiles).toList();
    if (paths.length > maxFiles) gaps.add('File read count limit reached.');
    var bytes = 0;
    var scanned = 0;
    var skipped = 0;
    for (final name in names) {
      if (cancellation.isCancelled) {
        gaps.add('Scan cancelled.');
        break;
      }
      if (!_eligible(name)) {
        failures[name] = 'Excluded by collection policy.';
        skipped++;
        continue;
      }
      final path = p.join(realRoot, name);
      try {
        await sandbox.validatePath(path);
        // Reject links even if they point within the project. Reject special
        // files before opening: a FIFO must never hang a repository scan.
        if (await FileSystemEntity.type(path, followLinks: false) !=
                FileSystemEntityType.file ||
            p.normalize(await File(path).resolveSymbolicLinks()) !=
                p.normalize(p.absolute(path))) {
          failures[name] = 'Not a regular file or path contains a symlink.';
          skipped++;
          continue;
        }
        final before = await File(path).stat();
        if (before.size > maxFileBytes) {
          failures[name] = 'File exceeds the $maxFileBytes-byte read limit.';
          skipped++;
          continue;
        }
        if (bytes + before.size > byteLimit) {
          failures[name] = 'File exceeds the remaining read budget.';
          gaps.add('Scan byte limit reached.');
          continue;
        }
        final data = <int>[];
        await for (final chunk in File(
          path,
        ).openRead(0, (byteLimit - bytes).clamp(0, maxFileBytes) + 1)) {
          if (cancellation.isCancelled) break;
          data.addAll(chunk);
        }
        bytes += data.length;
        if (cancellation.isCancelled) break;
        if (bytes > byteLimit) {
          gaps.add('Scan byte limit reached while a file was changing.');
          break;
        }
        final after = await File(path).stat();
        if (data.length > maxFileBytes ||
            before.size != after.size ||
            before.modified != after.modified ||
            data.contains(0)) {
          failures[name] =
              'File is binary, changed during read, or exceeds the read limit.';
          skipped++;
          continue;
        }
        final text = utf8.decode(data);
        scanned++;
        evidence.add(ProjectEvidence(name, text));
        if (scanned % 100 == 0) progress('Exploring: scanned $scanned files');
      } on FileSystemException {
        failures[name] = 'File is missing or inaccessible.';
        skipped++;
      } on SandboxViolation {
        failures[name] = 'Path is outside the permitted project scope.';
        skipped++;
      } on FormatException {
        failures[name] = 'File is not valid UTF-8 text.';
        skipped++;
      }
    }
    if (skipped > 0)
      gaps.add(
        '$skipped files skipped (excluded, binary, oversized, changed, inaccessible, or symlink).',
      );
    return EvidenceScan(
      evidence,
      scanned,
      gaps,
      readFailures: failures,
      bytesRead: bytes,
    );
  }

  Future<List<String>> _files(
    JudgmentCancellation cancellation,
    List<String> gaps,
  ) async {
    if (cancellation.isCancelled) return [];
    final stopped = Completer<void>();
    final detach = cancellation.listen(() => stopped.complete());
    try {
      final listing = await GitFileEnumerator(
        processes: processes,
        maxFiles: maxFiles,
        maxOutputBytes: 4 * 1024 * 1024,
      ).enumerate(root, cancelSignal: stopped.future);
      gaps.addAll(listing.gaps);
      if (listing.status == GitListingStatus.failed) {
        throw const JudgmentException(JudgmentFailure.invalidRequest);
      }
      return listing.paths;
    } finally {
      detach();
    }
  }
}

const _excluded = {
  'node_modules',
  'build',
  'dist',
  'target',
  'vendor',
  'venv',
  '__pycache__',
};
const _extensions = {
  '.dart',
  '.rs',
  '.go',
  '.py',
  '.js',
  '.jsx',
  '.ts',
  '.tsx',
  '.c',
  '.cc',
  '.cpp',
  '.h',
  '.hpp',
  '.java',
  '.kt',
  '.swift',
  '.m',
  '.mm',
  '.cs',
  '.rb',
  '.php',
  '.sh',
  '.sql',
  '.html',
  '.css',
  '.scss',
  '.vue',
  '.svelte',
  '.md',
  '.toml',
  '.yaml',
  '.yml',
  '.json',
};
bool _eligible(String name) {
  if (p.isAbsolute(name) || name.contains('\\')) return false;
  final parts = name.split('/');
  if (parts.any((part) => part.startsWith('.') || _excluded.contains(part)))
    return false;
  final lower = name.toLowerCase();
  // Exact credential filenames only. Source modules such as cancel_token.dart
  // or private_helpers.py are eligible; their names say nothing about relevance.
  if (const {
    'credentials.json',
    'credentials.yaml',
    'credentials.yml',
    'secrets.json',
    'secrets.yaml',
    'secrets.yml',
  }.contains(p.basename(lower)))
    return false;
  return _extensions.contains(p.extension(lower)) && !lower.endsWith('.lock');
}
