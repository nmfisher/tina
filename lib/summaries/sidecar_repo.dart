import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart' show summarySlug;

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
/// Directories never worth summarizing, shared by the default partition and
/// `repo_structure`'s folder review so the two surfaces agree on what counts
/// as a region candidate. Hidden entries (leading `.`) are skipped separately
/// by both callers.
const kDefaultPartitionSkip = <String>{'.dart_tool', 'build', 'dist'};

/// Invalidation is deterministic and lives here, not in the model: a
/// directory's summary is stale iff its `git rev-parse HEAD:<dir>` tree hash
/// differs from the manifest's recorded tree, or its working-tree digest
/// (`git status --porcelain`) differs from the recorded one, or it's new, or
/// deleted. This is the "only regenerate when code in *that* dir changes"
/// guarantee — extended to uncommitted changes, which never touch HEAD.
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
      if (name.startsWith('.') || kDefaultPartitionSkip.contains(name)) {
        continue;
      }
      dirs.add(name);
    }
    // Every packages/<pkg>/lib, so each package's library surface is
    // summarized on its own.
    final packagesDir = Directory(p.join(projectRoot.path, 'packages'));
    if (packagesDir.existsSync()) {
      for (final pkg in packagesDir.listSync(followLinks: false)) {
        if (pkg is! Directory) continue;
        final pkgName = p.basename(pkg.path);
        if (pkgName.startsWith('.') || kDefaultPartitionSkip.contains(pkgName)) {
          continue;
        }
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
  /// (re)generation. A dir is stale when
  /// - its HEAD tree hash differs from the manifest's (committed change),
  /// - its working-tree digest differs from the manifest's (uncommitted
  ///   change — covers clean→dirty, dirty→clean, and dirty content changing
  ///   while the dir stays dirty),
  /// - it is on disk but not at HEAD and unrecorded (a new, never-committed
  ///   dir), or it was recorded against a HEAD tree that no longer contains
  ///   it.
  /// A dir missing from disk (and recorded) is reported as deleted so the
  /// caller can remove its summary file.
  StaleSet staleDirs(List<String> partition, SummaryManifest manifest) {
    final stale = <String>[];
    final deleted = <String>[];
    for (final dir in partition) {
      final onDisk = Directory(p.join(projectRoot.path, dir)).existsSync();
      final current = _treeHashOrNull(dir);
      if (!onDisk && current == null) {
        // The dir is gone from disk and from HEAD. If we had a summary, it's
        // a deletion; otherwise it was never tracked.
        if (manifest.dirs.containsKey(dir)) {
          deleted.add(dir);
        }
        continue;
      }
      final recorded = manifest.dirs[dir];
      final digest = _dirtyDigest(dir);
      if (recorded == null) {
        // New to the manifest — stale whether tracked at HEAD or not.
        stale.add(dir);
      } else if (recorded.tree != current) {
        // Committed change (including a recorded dir that left HEAD, or an
        // unrecorded-at-HEAD dir that was later committed).
        stale.add(dir);
      } else if (recorded.dirtyDigest != digest) {
        // Same HEAD tree, different working tree.
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

  /// The summary file path for [dir] (manifest's recorded filename when
  /// present, else the slug-derived default), or null when the file does not
  /// exist.
  String? summaryFilePath(String dir) {
    final recorded = loadManifest().dirs[dir]?.file ?? '${summarySlug(dir)}.md';
    final file = File(p.join(_summariesDir.path, recorded));
    return file.existsSync() ? file.path : null;
  }

  /// The summary text for [dir], or null when the sidecar has none.
  String? readSummary(String dir) {
    final path = summaryFilePath(dir);
    if (path == null) return null;
    return File(path).readAsStringSync();
  }

  /// Whether the summary file the fleet would write for [dir] (the current
  /// slug-derived name) exists — i.e. a summarizer actually delivered. Used by
  /// [record] (don't record what wasn't written) and by callers computing
  /// honest post-run counts.
  bool summaryWritten(String dir) =>
      File(p.join(_summariesDir.path, '${summarySlug(dir)}.md')).existsSync();

  /// Update [manifest] for the dirs that were just regenerated: record each
  /// dir's current commit + tree (null when not at HEAD) + working-tree digest
  /// + summary filename. Removes [deleted] dirs. Returns the updated manifest
  /// (the caller then [saveManifest]s it).
  SummaryManifest record({
    required SummaryManifest manifest,
    required List<String> regenerated,
    required List<String> deleted,
  }) {
    final dirs = Map<String, DirSummary>.from(manifest.dirs);
    final commit = headCommit();
    for (final dir in regenerated) {
      if (!Directory(p.join(projectRoot.path, dir)).existsSync()) {
        continue; // vanished mid-run; skip rather than record.
      }
      if (!summaryWritten(dir)) {
        // The fleet planned this dir but never wrote its summary (a failed or
        // skipping summarizer). Recording it anyway would pin it as fresh at
        // the current tree — "no summary yet, run /index" meets "index is up
        // to date" and the dir deadlocks until its code changes. Leave it
        // unrecorded so it stays stale and resurfaces.
        continue;
      }
      dirs[dir] = DirSummary(
        commit: commit,
        tree: _treeHashOrNull(dir),
        dirtyDigest: _dirtyDigest(dir),
        file: '${summarySlug(dir)}.md',
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
  ///
  /// Staging is explicit — the manifest + the summary files only. A blanket
  /// `git add -A` would sweep the sidecar's mutable runtime files
  /// (allocations.json, the /index proposal marker) into summary history.
  void commit({
    required List<String> regenerated,
    required List<String> deleted,
    required String commitSha,
  }) {
    for (final dir in deleted) {
      final file = File(p.join(_summariesDir.path, '${summarySlug(dir)}.md'));
      if (file.existsSync()) file.deleteSync();
    }
    // Stage the manifest only when it exists (record() may have recorded
    // nothing — an entirely-skipped fleet run — leaving no manifest to stage).
    if (File(manifestPath).existsSync()) {
      _gitIn(_summariesDir.path, ['add', manifestPath]);
    }
    for (final dir in regenerated) {
      final path = p.join(_summariesDir.path, '${summarySlug(dir)}.md');
      if (File(path).existsSync()) {
        _gitIn(_summariesDir.path, ['add', path]);
      }
    }
    for (final dir in deleted) {
      // Staging a deleted (now absent) path records the removal.
      _gitIn(_summariesDir.path, ['add', '--', summarySlug(dir) + '.md']);
    }
    // Don't commit when there's nothing staged (avoids a noisy empty commit —
    // and an error, since unstaged runtime files like allocations.json would
    // otherwise make `status --porcelain` non-empty with an empty index).
    final staged = Process.runSync(
      'git',
      ['-C', _summariesDir.path, 'diff', '--cached', '--name-only'],
      runInShell: false,
    );
    final hasStaged =
        staged.exitCode == 0 && (staged.stdout as String).trim().isNotEmpty;
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

  /// A digest of [dir]'s working-tree state: an FNV-1a hash of
  /// `git status --porcelain -- <dir>` (`''` when clean). This is what makes
  /// uncommitted edits visible to the probe: untracked files appear as `??`
  /// entries, so a never-committed dir is always dirty. Hashing the full
  /// porcelain output (rather than a bool) also catches dirty content
  /// changing while the dir stays dirty.
  String _dirtyDigest(String dir) {
    final result = Process.runSync(
      'git',
      ['-C', projectRoot.path, 'status', '--porcelain', '--', dir],
      runInShell: false,
    );
    if (result.exitCode != 0) return '';
    final out = (result.stdout as String).trim();
    return out.isEmpty ? '' : _fnv1a(out);
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

/// FNV-1a 64-bit over [s], as hex. Not cryptographic — just a stable,
/// dependency-free digest that distinguishes porcelain outputs.
String _fnv1a(String s) {
  var hash = 0xcbf29ce484222325;
  for (final code in s.codeUnits) {
    hash ^= code;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16);
}

/// One directory's recorded summary tracking state.
class DirSummary {
  final String commit;

  /// The dir's HEAD tree hash when summarized; null when the dir wasn't at
  /// HEAD at all (never committed — tracked by [dirtyDigest] alone).
  final String? tree;

  /// The working-tree digest when summarized (`''` = clean, null = unknown —
  /// a manifest written before digests existed). A recorded non-null digest
  /// only differs from a probe on real change; null always re-summarizes once.
  final String? dirtyDigest;
  final String file;

  const DirSummary({
    required this.commit,
    required this.tree,
    required this.file,
    this.dirtyDigest,
  });

  Map<String, dynamic> toJson() => {
        'commit': commit,
        if (tree != null) 'tree': tree,
        // Written even when '' (known clean) — absent means unknown (a
        // pre-digest manifest), which the probe conservatively re-summarizes.
        if (dirtyDigest != null) 'dirty': dirtyDigest,
        'file': file,
      };

  factory DirSummary.fromJson(Map<String, dynamic> json) => DirSummary(
        commit: json['commit'] as String,
        tree: json['tree'] as String?,
        file: json['file'] as String,
        dirtyDigest: json['dirty'] as String?,
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
