import 'dart:io';

import 'package:tina/regions/region_registry.dart';
import 'package:tina/summaries/sidecar_repo.dart';
import 'package:test/test.dart';

import '../summaries/fleet_test_harness.dart';

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
    File('${sidecarRoot.path}/summaries/${dir.replaceAll('/', '__')}.md')
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

  test('a changed directory is flagged stale', () {
    seedSummary('lib');
    commit('lib', 'a.dart', 'int x = 2;\n');

    final lib = registry().find('lib')!;
    expect(lib.stale, isTrue);
  });

  test('allocated regions join the partition and persist across instances',
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
    expect([for (final r in r2.list()) r.dir], contains('lib/src'));
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
