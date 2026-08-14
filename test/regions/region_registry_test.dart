import 'dart:io';

import 'package:tina/regions/region_registry.dart';
import 'package:tina/summaries/sidecar_repo.dart';
import 'package:tina_engine/tina_engine.dart' show summarySlug;
import 'package:test/test.dart';

import '../summaries/fleet_test_harness.dart';

/// A [SidecarSummaryRepo] that counts [loadManifest] calls, to prove the
/// region list reads the manifest once (not once per region — the O(n²) bug).
class _CountingRepo extends SidecarSummaryRepo {
  _CountingRepo({required super.root, required super.projectRoot});
  int loadManifestCalls = 0;

  @override
  SummaryManifest loadManifest() {
    loadManifestCalls++;
    return super.loadManifest();
  }
}

/// Pins [RegionRegistry]: regions come from the default partition plus
/// allocations, summaries read back from the sidecar, staleness is the
/// pure-git probe, and allocate/forget persist through `allocations.json`.
void main() {
  late Directory tempRoot;
  late Directory project;
  late Directory sidecarRoot;
  late SidecarSummaryRepo repo;

  setUp(() {
    final t = buildTempProject();
    tempRoot = t.tempRoot;
    project = t.project;
    sidecarRoot = t.sidecarRoot;
    repo = SidecarSummaryRepo(root: sidecarRoot, projectRoot: project);
    repo.init();
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  RegionRegistry registry() => RegionRegistry(projectRoot: project.path);

  /// Seed a current summary for [dir] (matching the current tree hash, so it
  /// is not stale).
  void seedSummary(String dir, {String content = '# lib\n\nlib does X'}) {
    Directory('${sidecarRoot.path}/summaries').createSync(recursive: true);
    File('${sidecarRoot.path}/summaries/${summarySlug(dir)}.md')
        .writeAsStringSync(content);
    repo.saveManifest(repo.record(
      manifest: repo.loadManifest(),
      regenerated: [dir],
      deleted: const [],
    ));
  }

  void commit(String dir, String file, String content) {
    File('${project.path}/$dir/$file').writeAsStringSync(content);
    git(project, ['add', '-A']);
    git(project, ['commit', '-m', 'change $dir']);
  }

  test('list returns the default-partition regions with their summaries',
      () {
    seedSummary('lib');
    final regions = registry().list();

    expect([for (final r in regions) r.dir], ['lib']);
    final lib = regions.single;
    expect(lib.summarized, isTrue);
    expect(lib.summary, contains('lib does X'));
    expect(lib.commit, isNotNull);
    expect(lib.stale, isFalse);
  });

  /// A [SidecarSummaryRepo] that counts [loadManifest] so we can prove the
  /// region list reads the manifest once, not once per region (finding I).
  test('region summary reads reuse one manifest load (no O(n²) re-read)', () {
    seedSummary('lib');
    final counting = _CountingRepo(
        root: sidecarRoot, projectRoot: project);
    final manifest = counting.loadManifest();
    expect(counting.loadManifestCalls, 1);
    // The manifest-aware read resolves against the passed manifest — no
    // extra load.
    expect(counting.readSummaryWithManifest('lib', manifest),
        contains('lib does X'));
    expect(counting.loadManifestCalls, 1);
    // The legacy readSummary reloads each call (the O(n²) we removed).
    counting.readSummary('lib');
    expect(counting.loadManifestCalls, 2);
  });

  test('a changed directory is flagged stale', () {
    seedSummary('lib');
    commit('lib', 'a.dart', 'int x = 2;\n');

    final lib = registry().find('lib')!;
    expect(lib.stale, isTrue);
  });

  test('the allocated layout IS the partition and persists across instances',
      () {
    Directory('${project.path}/lib/src').createSync();
    commit('lib/src', 's.dart', 'int s = 1;\n');

    final r1 = registry();
    expect(r1.allocate('lib/src', model: 'deepseek/deepseek-chat'), isTrue);

    // A fresh instance reads the persisted allocation.
    final r2 = registry();
    final region = r2.find('lib/src')!;
    expect(region.dir, 'lib/src');
    expect(region.model, 'deepseek/deepseek-chat');
    // Allocated but never summarized → no summary, stale.
    expect(region.summarized, isFalse);
    expect(region.stale, isTrue);
    // Once any allocation exists, the layout IS the partition: the default
    // top-level dirs no longer appear.
    expect([for (final r in r2.list()) r.dir], ['lib/src']);
  });

  test('allocate refuses a missing directory', () {
    expect(registry().allocate('nope'), isFalse);
  });

  test('forget removes the allocation', () {
    Directory('${project.path}/lib/src').createSync();
    commit('lib/src', 's.dart', 'int s = 1;\n');
    final r = registry();
    expect(r.allocate('lib/src'), isTrue);
    r.forget('lib/src');

    expect(registry().find('lib/src'), isNull);
    expect([for (final x in registry().list()) x.dir], isNot(contains('lib/src')));
  });

  test('readSummary is null until the sidecar has one', () {
    final r = registry();
    expect(r.find('lib')!.summarized, isFalse);
    seedSummary('lib');
    expect(registry().find('lib')!.summarized, isTrue);
  });

  test('modelFor resolves allocation, then the registry default', () {
    final r1 = registry();
    expect(r1.modelFor('lib'), isNull);
    final r2 = RegionRegistry(
        projectRoot: project.path, defaultModel: 'deepseek/deepseek-chat');
    expect(r2.modelFor('lib'), 'deepseek/deepseek-chat');
    r2.allocate('lib', model: 'fast/fast-model');
    expect(registry().modelFor('lib'), 'fast/fast-model');
  });
}
