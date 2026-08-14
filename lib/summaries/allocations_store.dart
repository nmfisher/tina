import 'dart:convert';
import 'dart:io';

import 'sidecar_repo.dart';

/// The partition: the allocated regions when any exist — the main agent's
/// proposed layout IS the index — else the deterministic default partition
/// (the headless `--prompt /index` fallback, where no main agent proposes).
List<String> partitionFor(SidecarSummaryRepo repo, AllocationsStore? allocations) {
  final allocated = allocations?.dirs ?? const <String>[];
  if (allocated.isNotEmpty) return allocated;
  return repo.defaultPartition();
}

/// One user-allocated region: a directory the main agent chose to give its
/// own summary, optionally with a dedicated fast model.
class Allocation {
  final String dir;
  final String? model;

  const Allocation({required this.dir, this.model});

  Map<String, dynamic> toJson() =>
      model == null ? <String, dynamic>{} : {'model': model};

  factory Allocation.fromJson(String dir, Map<String, dynamic> json) =>
      Allocation(dir: dir, model: json['model'] as String?);
}

/// The user-allocated region partition: a small `allocations.json` in the
/// sidecar root (`<projectRoot>/.tina/summaries/allocations.json`) recording
/// which directories the main agent allocated. Kept separate from
/// `manifest.json` so the summary manifest schema is untouched. The partition
/// for staleness/refresh is the allocated regions when any exist (see
/// [partitionFor]), else `defaultPartition()`.
class AllocationsStore {
  AllocationsStore({required this.sidecarRoot});

  /// The store for [projectRoot]'s sidecar
  /// (`<projectRoot>/.tina/summaries/allocations.json`).
  factory AllocationsStore.forProject(String projectRoot) =>
      AllocationsStore(sidecarRoot: Directory('$projectRoot/.tina/summaries'));

  /// The sidecar git repo root: `<projectRoot>/.tina/summaries`.
  final Directory sidecarRoot;

  File get _file => File('${sidecarRoot.path}/allocations.json');

  /// The allocated dirs in insertion order.
  List<Allocation> list() {
    final file = _file;
    if (!file.existsSync()) return const [];
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final regions = json['regions'] as Map<String, dynamic>? ?? const {};
      return [
        for (final entry in regions.entries)
          Allocation.fromJson(entry.key, entry.value as Map<String, dynamic>? ?? const {}),
      ];
    } on FormatException {
      // Corrupt store: start fresh rather than blocking the session.
      return const [];
    }
  }

  /// The allocated directories, in insertion order.
  List<String> get dirs => [for (final a in list()) a.dir];

  String? modelFor(String dir) {
    for (final a in list()) {
      if (a.dir == dir) return a.model;
    }
    return null;
  }

  bool contains(String dir) => dirs.contains(dir);

  /// Upsert [dir] (optionally with a region model). Creates the sidecar dir
  /// when needed.
  void set({required String dir, String? model}) {
    final entries = {for (final a in list()) a.dir: a};
    entries[dir] = Allocation(dir: dir, model: model);
    _save(entries.values.toList());
  }

  void remove(String dir) {
    final entries = {for (final a in list()) a.dir: a}..remove(dir);
    _save(entries.values.toList());
  }

  void _save(List<Allocation> allocations) {
    sidecarRoot.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'regions': {for (final a in allocations) a.dir: a.toJson()},
      }),
    );
  }
}
