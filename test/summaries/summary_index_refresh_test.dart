// End-to-end test for [SummaryIndex.refresh] — the façade's fleet-driving path
// that [index_command_test] stubs out. Runs the real fleet (orchestrator →
// delegate → summarizer → write_summary) via the shared [fleet_test_harness]
// against a temp git repo, and asserts the sidecar is populated + committed,
// the registry decorator is restored (so an in-process /index doesn't leak),
// and `repartition` forces a re-run even when the index is up to date.

import 'dart:async';
import 'dart:io';

import 'package:tina/platform/environment.dart';
import 'package:tina/summaries/allocations_store.dart';
import 'package:tina/summaries/sidecar_repo.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import 'fleet_test_harness.dart';

void main() {
  late Directory tempRoot;
  late Directory project;
  late Directory sidecarRoot;
  late ScriptedFleetProvider provider;

  setUp(() {
    final t = buildTempProject();
    tempRoot = t.tempRoot;
    project = t.project;
    sidecarRoot = t.sidecarRoot;
    provider = ScriptedFleetProvider();
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  SummaryIndex _index(ProviderRegistry registry) => SummaryIndex(
        config: testFleetConfig(registry),
        registry: registry,
        environment: const PlatformEnvironment(),
        projectRoot: project.path,
      );

  SidecarSummaryRepo _repo() =>
      SidecarSummaryRepo(root: sidecarRoot, projectRoot: project);

  /// Allocations over the default partition (the main agent's proposed layout
  /// — it REPLACES the default), seeded via the real store.
  AllocationsStore _allocations(List<String> dirs) {
    final store =
        AllocationsStore(sidecarRoot: Directory('${project.path}/.tina/summaries'));
    for (final d in dirs) store.set(dir: d);
    return store;
  }

  test('refresh runs the fleet, writes the sidecar, restores the decorator',
      () async {
    final registry = anthropicRegistry(provider);
    // Sentinel the live session would have set at startup; refresh must leave
    // it intact despite SummaryRunner's buildAppComposition re-setting it.
    final sentinel = (LlmProvider p) => p;
    registry.decorator = sentinel;
    final idx = _index(registry);

    final before = await idx.status();
    expect(before.firstRun, isTrue);
    expect(before.allStale, isTrue);

    final r = await idx.refresh().timeout(const Duration(seconds: 30));
    expect(r.regenerated, greaterThan(0));
    expect(r.regeneratedDirs, contains('lib'));

    // Sidecar file with the summarizer's content + a stamped header.
    final file = File('${sidecarRoot.path}/summaries/lib.md');
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('lib does X'));
    // Manifest tracks lib.
    expect(_repo().loadManifest().dirs['lib'], isNotNull);
    // A sidecar commit was recorded.
    expect(
        git(Directory('${sidecarRoot.path}/summaries'), ['log', '--oneline']),
        contains('summaries @'));

    // The caller's decorator survived the in-process fleet run.
    expect(registry.decorator, same(sentinel));

    // Post-run status is up to date.
    final after = await idx.status();
    expect(after.firstRun, isFalse);
    expect(after.staleCount, 0);
  });

  test('refresh(repartition: true) regenerates even when up to date', () async {
    final registry = anthropicRegistry(provider);
    final idx = _index(registry);

    // Seed an up-to-date manifest so a non-repartition refresh would no-op —
    // summary files first, since record() only records what was written.
    final seed = _repo();
    seed.init();
    final partition = seed.defaultPartition();
    for (final dir in partition) {
      File('${sidecarRoot.path}/summaries/${summarySlug(dir)}.md')
          .writeAsStringSync('# $dir\n');
    }
    seed.saveManifest(seed.record(
      manifest: seed.loadManifest(),
      regenerated: partition,
      deleted: const [],
    ));
    expect((await idx.status()).staleCount, 0);

    // repartition clears the manifest → all stale → the fleet runs anyway.
    final r =
        await idx.refresh(repartition: true).timeout(const Duration(seconds: 30));
    expect(r.regenerated, partition.length);
    expect(r.regeneratedDirs, contains('lib'));
    // The file was (re)written.
    expect(File('${sidecarRoot.path}/summaries/lib.md').existsSync(), isTrue);
    expect(
        git(Directory('${sidecarRoot.path}/summaries'), ['log', '--oneline']),
        contains('summaries @'));
  });

  test('refresh(dirs:) regenerates only the requested dirs', () async {
    // A second stale dir so the filter is observable.
    Directory('${project.path}/packages/foo/lib').createSync(recursive: true);
    File('${project.path}/packages/foo/lib/f.dart').writeAsStringSync('// f\n');
    git(project, ['add', '-A']);
    git(project, ['commit', '-m', 'add package']);
    // And make lib stale too.
    File('${project.path}/lib/a.dart').writeAsStringSync('int x = 2;\n');
    git(project, ['add', '-A']);
    git(project, ['commit', '-m', 'bump lib']);

    final registry = anthropicRegistry(provider);
    final idx = _index(registry);
    final before = await idx.status();
    expect(before.staleDirs, containsAll(['lib', 'packages/foo/lib']));

    final r =
        await idx.refresh(dirs: ['lib']).timeout(const Duration(seconds: 30));
    expect(r.regenerated, 1);
    expect(r.regeneratedDirs, ['lib']);

    // Only lib was regenerated; the other stale dirs (packages — whose tree
    // changed when the package was added — and the package lib) stay stale.
    final after = await idx.status();
    expect(after.staleDirs, isNot(contains('lib')));
    expect(after.staleDirs, contains('packages/foo/lib'));
    expect(File('${sidecarRoot.path}/summaries/lib.md').existsSync(), isTrue);
    expect(
        File('${sidecarRoot.path}/summaries/packages%2Ffoo%2Flib.md')
            .existsSync(),
        isFalse);
  });

  test('an in-process refresh merges the fleet spend into the live ledger',
      () async {
    final registry = anthropicRegistry(provider);
    final live = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
    final idx = SummaryIndex(
      config: testFleetConfig(registry),
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
      spendLedger: live,
    );

    final r = await idx.refresh().timeout(const Duration(seconds: 30));
    expect(r.regenerated, greaterThan(0));

    // The scripted fleet makes 4 provider sends × 150 tokens each; all of it
    // landed in the live session ledger, not a throwaway.
    expect(live.totalTokens, 600);
  });

  test('refresh respects the allocated partition only (finding A)', () async {
    final registry = anthropicRegistry(provider);
    final idx = SummaryIndex(
      config: testFleetConfig(registry),
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
      allocations: _allocations(['lib']),
    );

    final r = await idx.refresh().timeout(const Duration(seconds: 30));
    // Only the allocated dir was regenerated — not the default top-level dirs.
    expect(r.regeneratedDirs, ['lib']);

    // The manifest tracks only lib, and a follow-up status is clean (the old
    // "Indexed 0 forever" loop — probe measured allocations, fleet default —
    // is gone).
    final manifest = _repo().loadManifest();
    expect(manifest.dirs.keys, ['lib']);

    final after = await idx.status();
    expect(after.totalDirs, 1);
    expect(after.staleCount, 0);
    expect(after.allStale, isFalse);
  });

  test('refresh routes fleet output to the injected host, not stdout',
      () async {
    final registry = anthropicRegistry(provider);
    final idx = _index(registry);
    final host = FakeHostInterface();
    await idx.refresh(host: host).timeout(const Duration(seconds: 30));
    // The fleet streamed its tool activity into the injected host's sink, not
    // the HeadlessHost that writes raw stdout over the TUI.
    expect(host.sink.toolStarts, isNotEmpty);
  });

  test('refresh cancels mid-fleet via cancelSignal and records nothing',
      () async {
    final registry = anthropicRegistry(provider);
    final idx = _index(registry);
    // A pre-completed cancel signal → the orchestrator aborts before any
    // delegate runs, so no summary file is written and record() records
    // nothing. Whether the run throws or returns, the sidecar stays empty.
    final cancel = Completer<void>()..complete();
    try {
      await idx.refresh(cancelSignal: cancel.future)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      // Cancellation may surface as an error — either outcome is fine here.
    }
    expect(File('${sidecarRoot.path}/summaries/lib.md').existsSync(), isFalse);
  });
}
