// End-to-end test for [SummaryRunner]: drives the real headless fleet (an
// orchestrator that delegates to `summarizer`) against a stub [LlmProvider],
// and asserts the summary file lands in the sidecar + a commit is recorded.
//
// Mirrors the engine's headless test patterns: a scripted registry drives a
// real [SubAgentScheduler] + [DelegateTool]; we never spin a REPL. The temp
// project is a real git repo so the tool's `git rev-parse` header resolves and
// the sidecar commits land somewhere isolated.
//
// The fleet scaffolding (temp project, scripted provider, registry/config
// wiring) lives in `fleet_test_harness.dart`, shared with the [SummaryIndex]
// tests.

import 'dart:io';

import 'package:tina/platform/environment.dart';
import 'package:tina/summaries/sidecar_repo.dart';
import 'package:tina/summaries/summary_runner.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

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

  test('the fleet writes a summary file + records a sidecar commit', () async {
    final registry = anthropicRegistry(provider);
    final config = testFleetConfig(registry);
    final runner = SummaryRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    );

    final stale = await runner.run().timeout(const Duration(seconds: 30));

    // The lib directory was stale → regenerated.
    expect(stale.toRegenerate, contains('lib'));
    // The summary file exists with the summarizer's content + a stamped header.
    final file = File('${sidecarRoot.path}/summaries/lib.md');
    expect(file.existsSync(), isTrue,
        reason: 'summarizer should have written lib.md');
    final text = file.readAsStringSync();
    expect(text, startsWith('<!-- tina-summary dir="lib"'));
    expect(text, contains('lib does X'));
    // The sidecar recorded a git commit.
    final log =
        git(Directory('${sidecarRoot.path}/summaries'), ['log', '--oneline']);
    expect(log, contains('summaries @'));
    // The manifest now tracks lib with a tree hash.
    final manifest = SidecarSummaryRepo(
      root: sidecarRoot,
      projectRoot: project,
    ).loadManifest();
    expect(manifest.dirs['lib'], isNotNull);
    expect(manifest.dirs['lib']!.file, 'lib.md');
  });

  test('run() restores the registry decorator it temporarily mutates',
      () async {
    // buildAppComposition re-sets registry.decorator to a fresh
    // MeteringProvider/SpendLedger during the run. SummaryRunner must restore
    // the caller's decorator afterward so an in-process /index run doesn't
    // leak the ephemeral (disposed) ledger into later /spawn /model builds.
    final registry = anthropicRegistry(provider);
    // Pin a sentinel decorator the live session would have set at startup.
    final sentinel = (LlmProvider p) => p;
    registry.decorator = sentinel;
    final runner = SummaryRunner(
      config: testFleetConfig(registry),
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    );

    await runner.run().timeout(const Duration(seconds: 30));

    expect(registry.decorator, same(sentinel),
        reason: 'the caller\'s registry.decorator must be restored after run');
  });

  test('dry-run reports stale dirs without calling the model', () async {
    final registry = anthropicRegistry(provider);
    final runner = SummaryRunner(
      config: testFleetConfig(registry),
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
      dryRun: true,
    );
    final stale = await runner.run().timeout(const Duration(seconds: 10));
    expect(stale.toRegenerate, contains('lib'));
    // No provider call in dry-run.
    expect(provider.callCount, 0);
    // No summary file written.
    expect(File('${sidecarRoot.path}/summaries/lib.md').existsSync(), isFalse);
  });
}
