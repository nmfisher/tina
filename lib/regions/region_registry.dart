import 'dart:io';

import 'package:path/path.dart' as p;

import '../summaries/allocations_store.dart';
import '../summaries/sidecar_repo.dart';

/// One region: a summarized directory the main agent can query. A region is a
/// logical entity — it exists because its directory is in the partition (the
/// default top-level dirs plus any user allocation) and it is "primed" with
/// its summary text; no agent runs until a query is dispatched to it.
class Region {
  /// Repo-relative directory path (e.g. `lib` or `packages/tina_engine/lib`).
  final String dir;

  /// The full summary text from the sidecar; null when the dir has not been
  /// summarized yet (first run, or never indexed).
  final String? summary;

  /// The main-repo commit the summary was stamped against; null when none.
  final String? commit;

  /// Whether the region's code changed since its summary was written (tree
  /// hash differs). Staleness is a pure-git probe — no LLM.
  final bool stale;

  /// The region's dedicated model (`"provider/model"`), from its allocation;
  /// null = inherit the default.
  final String? model;

  const Region({
    required this.dir,
    required this.summary,
    required this.commit,
    required this.stale,
    required this.model,
  });

  bool get summarized => summary != null && summary!.isNotEmpty;
}

/// The read side of the summary sidecar, shaped for region agents: which
/// regions exist (the allocated layout when any exists, else the default
/// partition), their summaries, and staleness. Constructed once at session
/// start — pure file/git reads, zero LLM calls — so every region is "ready"
/// the moment the session loads.
class RegionRegistry {
  RegionRegistry({
    required this.projectRoot,
    this.defaultModel,
    AllocationsStore? allocations,
  })  : _allocations = allocations ?? AllocationsStore.forProject(projectRoot),
        _repo = SidecarSummaryRepo(
          root: Directory('$projectRoot/.tina'),
          projectRoot: Directory(projectRoot),
        );

  /// The main repo root being served.
  final String projectRoot;

  /// The default `"provider/model"` for region queries (from `[regions] model`
  /// in the user config); overridden per-region by an allocation.
  final String? defaultModel;

  final AllocationsStore _allocations;
  final SidecarSummaryRepo _repo;

  /// The user-allocated regions store (for `allocate_region`/`forget_region`).
  AllocationsStore get allocations => _allocations;

  /// Every region, in partition order: the allocated regions when any exist
  /// (the main agent's layout IS the index), else the default top-level dirs.
  List<Region> list() {
    final manifest = _repo.loadManifest();
    final dirs = partitionFor(_repo, _allocations);
    final stale = _repo.staleDirs(dirs, manifest).toRegenerate.toSet();
    return [for (final dir in dirs) _regionFor(dir, manifest, stale)];
  }

  /// The region for [dir], or null when it is not in the partition.
  Region? find(String dir) {
    for (final r in list()) {
      if (r.dir == dir) return r;
    }
    return null;
  }

  /// The resolved model for [dir]: the allocation's override, else the
  /// registry default, else null (inherit the main agent's model).
  String? modelFor(String dir) =>
      _allocations.modelFor(dir) ?? defaultModel;

  /// Allocate [dir] as a region, optionally with a dedicated fast model.
  /// Returns false when the dir does not exist under [projectRoot] (a nested
  /// path is fine — the slug handles it).
  bool allocate(String dir, {String? model}) {
    if (!Directory(p.join(projectRoot, dir)).existsSync()) return false;
    _allocations.set(dir: dir, model: model);
    return true;
  }

  /// Remove the allocation for [dir] (the dir drops out of the partition).
  void forget(String dir) => _allocations.remove(dir);

  Region _regionFor(
      String dir, SummaryManifest manifest, Set<String> staleSet) {
    final recorded = manifest.dirs[dir];
    return Region(
      dir: dir,
      // Manifest-aware read: list() loaded the manifest once for the whole
      // partition — readSummary would re-read + re-parse it per region.
      summary: _repo.readSummaryWithManifest(dir, manifest),
      commit: recorded?.commit,
      stale: staleSet.contains(dir),
      model: _allocations.modelFor(dir),
    );
  }
}
