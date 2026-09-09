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

/// A repository snapshot of the sidecar's staleness — the answer to "should
/// `/index` do anything, and what?". Carries everything the command handler
/// needs to branch + message without an LLM call.
class SummaryIndexStatus {
  final int totalDirs;
  final List<String> staleDirs;
  final List<String> deletedDirs;
  final String? headSha;
  final bool firstRun;

  /// Whether the main agent has allocated regions (the proposed layout exists
  /// but nothing is summarized yet on a first run).
  final bool hasAllocations;

  /// Whether `.tina/ENVIRONMENT.md` is absent — the main agent's first-load
  /// signal. Pure file read, like the rest of this probe.
  final bool envFirstLoad;

  /// Why the environment region is stale, or null when current. From the
  /// machine-owned tracking entry under `.tina/environment/`, never from the
  /// record's prose.
  final String? envStaleReason;

  const SummaryIndexStatus({
    required this.totalDirs,
    required this.staleDirs,
    required this.deletedDirs,
    required this.headSha,
    required this.firstRun,
    this.hasAllocations = false,
    this.envFirstLoad = false,
    this.envStaleReason,
  });

  /// The environment region is stale (first load counts — nothing measured).
  bool get envStale => envFirstLoad || envStaleReason != null;

  int get staleCount => staleDirs.length;

  /// Every directory is stale — either a first run (empty manifest) or every
  /// tracked dir changed since the last index. The command handler treats this
  /// as "index all".
  bool get allStale => staleCount == totalDirs && totalDirs > 0;
}

/// The outcome of a [SummaryIndex.refresh] run: what was regenerated/deleted
/// plus the post-run status (which is up-to-date, modulo anything that changed
/// mid-run).
class SummaryIndexResult {
  final SummaryIndexStatus status;
  final StaleSet planned;
  final int regenerated;
  final List<String> regeneratedDirs;
  final List<String> deletedDirs;

  const SummaryIndexResult({
    required this.status,
    this.planned = const StaleSet(toRegenerate: [], deleted: []),
    required this.regenerated,
    required this.regeneratedDirs,
    required this.deletedDirs,
  });
}
