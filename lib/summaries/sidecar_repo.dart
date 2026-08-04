import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The per-directory summary sidecar: a standalone git repo under
/// `<projectRoot>/.tina/summaries/` that tracks the main repo from outside
/// its tracked tree. `.tina/` is gitignored by the main repo, so the sidecar
/// lives fully outside the main repo's history.
///
/// One markdown file per summarized directory; `manifest.json` is the
/// authoritative partition + per-dir `{commit, tree, file}`. This class owns
/// the git plumbing (init, manifest round-trip, staleness, commit) and the
/// partition — pure `Process.runSync('git', ...)`, no LLM.
///
/// Invalidation is deterministic and lives here, not in the model: a
/// directory's summary is stale iff its `git rev-parse HEAD:<dir>` tree hash
/// differs from the manifest's recorded tree (or it's new, or deleted). This is
/// the "only regenerate when code in *that* dir changes" guarantee.
class SidecarSummaryRepo {
  SidecarSummaryRepo({
    required this.root,
    required this.projectRoot,
  })  : _summariesDir = Directory(p.join(root.path, 'summaries')),
        manifestPath = p.join(root.path, 'summaries', 'manifest.json');

  /// The sidecar git repo root: `<projectRoot>/.tina/summaries`.
  final Directory root;

  /// The main repo root, for `git -C` and `rev-parse HEAD:<dir>`.
  final Directory projectRoot;

  final Directory _summariesDir;
  final String manifestPath;

  /// Ensure the sidecar repo exists: create the dir and `git init` on first
  /// run. Idempotent — a no-op when already initialized.
  void init() {
    if (!_summariesDir.existsSync()) {
      _summariesDir.createSync(recursive: true);
    }
    if (!_isGitRepo(_summariesDir.path)) {
      _gitIn(_summariesDir.path, ['init']);
    }
  }

  /// Load the manifest, or an empty one when none exists yet (first run).
  SummaryManifest loadManifest() {
    final file = File(manifestPath);
    if (!file.existsSync()) return SummaryManifest.empty();
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return SummaryManifest.fromJson(json);
    } on FormatException {
      // Corrupt manifest: start fresh rather than blocking the run.
      return SummaryManifest.empty();
    }
  }

  /// Persist the manifest to [manifestPath].
  void saveManifest(SummaryManifest manifest) {
    final file = File(manifestPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(_prettyJson(manifest.toJson()));
  }

  /// The default partition: top-level directories of [projectRoot] plus every
  /// `packages/*/lib` directory. Stable across runs (the manifest's key set is
  /// the pin), so a change in the partition only adds/removes keys here.
  ///
  /// Hidden entries (leading `.`) and non-directories are skipped, matching the
  /// summarizer's own listing convention.
  List<String> defaultPartition() {
    final dirs = <String>[];
    // Top-level directories (repo-relative).
    for (final entry in projectRoot.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('.')) continue;
      dirs.add(name);
    }
    // Every packages/<pkg>/lib, so each package's library surface is
    // summarized on its own.
    final packagesDir = Directory(p.join(projectRoot.path, 'packages'));
    if (packagesDir.existsSync()) {
      for (final pkg in packagesDir.listSync(followLinks: false)) {
        if (pkg is! Directory) continue;
        final pkgName = p.basename(pkg.path);
        if (pkgName.startsWith('.')) continue;
        final lib = Directory(p.join(pkg.path, 'lib'));
        if (lib.existsSync()) {
          dirs.add('packages/$pkgName/lib');
        }
      }
    }
    dirs.sort();
    return dirs;
  }

  /// Compute the stale set against [partition]: every directory that needs
  /// (re)generation. A dir is stale when its current tree hash differs from the
  /// manifest's, missing from the manifest (new), or missing on disk (deleted —
  /// reported so the caller can remove its summary file).
  StaleSet staleDirs(List<String> partition, SummaryManifest manifest) {
    final stale = <String>[];
    final deleted = <String>[];
    for (final dir in partition) {
      final current = _treeHashOrNull(dir);
      if (current == null) {
        // The dir no longer exists on disk at HEAD. If we had a summary, it's
        // a deletion; otherwise it was never tracked.
        if (manifest.dirs.containsKey(dir)) {
          deleted.add(dir);
        }
        continue;
      }
      final recorded = manifest.dirs[dir]?.tree;
      if (recorded == null || recorded != current) {
        stale.add(dir);
      }
    }
    // Dirs in the manifest but no longer in the partition are also deletions
    // (the partition shrank).
    final partitionSet = partition.toSet();
    for (final dir in manifest.dirs.keys) {
      if (!partitionSet.contains(dir)) {
        deleted.add(dir);
      }
    }
    return StaleSet(toRegenerate: stale, deleted: deleted.toSet().toList()..sort());
  }

  /// The current main-repo HEAD commit sha. Used to stamp the manifest + the
  /// commit message.
  String headCommit() => _gitIn(projectRoot.path, ['rev-parse', 'HEAD']);

  /// The current tree hash for [dir] at HEAD, or null when the dir is absent.
  String? treeHash(String dir) => _treeHashOrNull(dir);

  /// Update [manifest] for the dirs that were just regenerated: record each
  /// dir's current commit + tree + summary filename. Removes [deleted] dirs.
  /// Returns the updated manifest (the caller then [saveManifest]s it).
  SummaryManifest record({
    required SummaryManifest manifest,
    required List<String> regenerated,
    required List<String> deleted,
  }) {
    final dirs = Map<String, DirSummary>.from(manifest.dirs);
    final commit = headCommit();
    for (final dir in regenerated) {
      final tree = _treeHashOrNull(dir);
      if (tree == null) continue; // vanished mid-run; skip rather than record.
      dirs[dir] = DirSummary(
        commit: commit,
        tree: tree,
        file: '${_slug(dir)}.md',
      );
    }
    for (final dir in deleted) {
      dirs.remove(dir);
    }
    return SummaryManifest(dirs: dirs);
  }

  /// Remove the summary files for [deleted] dirs from the sidecar, then commit
  /// the whole set (regenerated + deleted) with a descriptive message. A no-op
  /// commit when there is nothing staged (the caller may still want to save the
  /// manifest, though).
  void commit({
    required List<String> regenerated,
    required List<String> deleted,
    required String commitSha,
  }) {
    for (final dir in deleted) {
      final file = File(p.join(_summariesDir.path, '${_slug(dir)}.md'));
      if (file.existsSync()) file.deleteSync();
    }
    _gitIn(_summariesDir.path, ['add', '-A']);
    // Don't commit when there's nothing staged (avoids a noisy empty commit).
    final hasStaged = _gitIn(_summariesDir.path, ['status', '--porcelain']).isNotEmpty;
    if (!hasStaged) return;
    final short = commitSha.length >= 7 ? commitSha.substring(0, 7) : commitSha;
    final parts = <String>[];
    if (regenerated.isNotEmpty) parts.add('${regenerated.length} regenerated');
    if (deleted.isNotEmpty) parts.add('${deleted.length} deleted');
    final summary = parts.isEmpty ? 'summaries' : parts.join(', ');
    _gitIn(_summariesDir.path, [
      'commit',
      '-m',
      'summaries @ $short: $summary',
    ]);
  }

  /// `git rev-parse HEAD:<dir>` for [dir], or null when the dir is absent at
  /// HEAD (rev-parse fails on a missing path).
  String? _treeHashOrNull(String dir) {
    final result = Process.runSync(
      'git',
      ['-C', projectRoot.path, 'rev-parse', 'HEAD:$dir'],
      runInShell: false,
    );
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  }

  bool _isGitRepo(String path) {
    final result = Process.runSync(
      'git',
      ['-C', path, 'rev-parse', '--is-inside-work-tree'],
      runInShell: false,
    );
    return result.exitCode == 0;
  }

  String _gitIn(String dir, List<String> args) {
    final result = Process.runSync(
      'git',
      ['-C', dir, ...args],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw ProcessException(
        'git',
        args,
        err.isEmpty ? 'git exited ${result.exitCode} in $dir' : err,
      );
    }
    return (result.stdout as String).trim();
  }

  String _prettyJson(Map<String, dynamic> json) =>
      const JsonEncoder.withIndent('  ').convert(json);
}

/// One directory's recorded summary tracking state.
class DirSummary {
  final String commit;
  final String tree;
  final String file;

  const DirSummary({
    required this.commit,
    required this.tree,
    required this.file,
  });

  Map<String, dynamic> toJson() => {
        'commit': commit,
        'tree': tree,
        'file': file,
      };

  factory DirSummary.fromJson(Map<String, dynamic> json) => DirSummary(
        commit: json['commit'] as String,
        tree: json['tree'] as String,
        file: json['file'] as String,
      );
}

/// The manifest: the authoritative partition (its key set) + per-dir tracking.
class SummaryManifest {
  final Map<String, DirSummary> dirs;

  const SummaryManifest({required this.dirs});

  factory SummaryManifest.empty() => const SummaryManifest(dirs: {});

  factory SummaryManifest.fromJson(Map<String, dynamic> json) {
    final raw = json['dirs'] as Map<String, dynamic>? ?? const {};
    return SummaryManifest(
      dirs: {
        for (final entry in raw.entries)
          entry.key: DirSummary.fromJson(entry.value as Map<String, dynamic>),
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'dirs': {for (final entry in dirs.entries) entry.key: entry.value.toJson()},
      };
}

/// The staleness result: which dirs to regenerate, which to delete.
class StaleSet {
  final List<String> toRegenerate;
  final List<String> deleted;

  const StaleSet({required this.toRegenerate, required this.deleted});

  bool get isEmpty => toRegenerate.isEmpty && deleted.isEmpty;
}

/// Slug a repo-relative dir path into a flat filename. Mirrors
/// [WriteSummaryTool]'s slug so the tool and the repo agree on filenames.
String _slug(String dir) =>
    p.normalize(dir).replaceAll(RegExp(r'/+'), '__');
