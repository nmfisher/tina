import 'dart:io';

import 'package:tina/regions/region_registry.dart';
import 'package:tina/regions/region_tools.dart';
import 'package:tina/summaries/sidecar_repo.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../summaries/fleet_test_harness.dart';

/// A scheduler stub that records the runStandalone arguments instead of
/// running an agent (mirrors test/pipeline_test.dart's _RecordingScheduler).
class _RecordingScheduler extends SubAgentScheduler {
  final List<
      ({
        String systemPrompt,
        String task,
        String? modelReference,
        ToolProfile toolProfile,
        bool includeDelegate,
      })> calls = [];

  _RecordingScheduler()
      : super(
          registry: ProviderRegistry(env: const {}),
          pipeline: defaultPipeline,
          maxTokens: 1000,
          streamIdleTimeout: const Duration(seconds: 10),
          requestTimeout: const Duration(seconds: 10),
        );

  @override
  Future<RunAgentResult> runStandalone({
    required String systemPrompt,
    required String task,
    String parentReference = '',
    String? modelReference,
    List<Message>? seedHistory,
    Future<void>? cancelSignal,
    required AgentSink sink,
    ToolProfile toolProfile = ToolProfile.full,
    bool includeDelegate = true,
  }) async {
    calls.add((
      systemPrompt: systemPrompt,
      task: task,
      modelReference: modelReference,
      toolProfile: toolProfile,
      includeDelegate: includeDelegate,
    ));
    return RunAgentResult('report for $task');
  }
}

/// A SummaryIndex stub that records refresh(dirs:) without running the fleet.
class _StubIndex extends SummaryIndex {
  _StubIndex() : super(projectRoot: '.');
  int refreshes = 0;
  List<String>? lastDirs;

  @override
  Future<SummaryIndexResult> refresh({
    bool repartition = false,
    List<String>? dirs,
  }) async {
    refreshes++;
    lastDirs = dirs;
    return const SummaryIndexResult(
      status: SummaryIndexStatus(
          totalDirs: 0,
          staleDirs: [],
          deletedDirs: [],
          headSha: null,
          firstRun: false),
      regenerated: 0,
      regeneratedDirs: [],
      deletedDirs: [],
    );
  }
}

/// Pins the six region tools: discovery/read/query dispatch through the
/// registry + scheduler seams, and allocate/forget mutate the partition.
void main() {
  late Directory tempRoot;
  late Directory project;
  late Directory sidecarRoot;
  late SidecarSummaryRepo repo;
  late RegionRegistry regions;
  late _RecordingScheduler scheduler;

  setUp(() {
    final t = buildTempProject();
    tempRoot = t.tempRoot;
    project = t.project;
    sidecarRoot = t.sidecarRoot;
    repo = SidecarSummaryRepo(root: sidecarRoot, projectRoot: project);
    repo.init();
    regions = RegionRegistry(projectRoot: project.path);
    scheduler = _RecordingScheduler();
    // A second, allocated region so broadcast has two targets.
    Directory('${project.path}/lib/src').createSync();
    File('${project.path}/lib/src/s.dart').writeAsStringSync('int s = 1;\n');
    git(project, ['add', '-A']);
    git(project, ['commit', '-m', 'add lib/src']);
    regions.allocate('lib/src', model: 'fast/fast-model');
    // Seed a current summary for lib.
    Directory('${sidecarRoot.path}/summaries').createSync(recursive: true);
    File('${sidecarRoot.path}/summaries/lib.md')
        .writeAsStringSync('# lib\n\nlib does X');
    repo.saveManifest(repo.record(
      manifest: repo.loadManifest(),
      regenerated: ['lib'],
      deleted: const [],
    ));
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
    scheduler.dispose();
  });

  group('list_regions', () {
    test('lists regions with a summary digest', () async {
      final r = await ListRegionsTool(regions).execute({});
      expect(r.isError, isFalse);
      expect(r.content,contains('2 region(s)'));
      expect(r.content,contains('lib'));
      expect(r.content,contains('lib/src'));
      expect(r.content,contains('lib does X'));
      expect(r.content,contains('fast/fast-model'));
    });

    test('no regions when the sidecar is empty', () async {
      final empty = Directory.systemTemp.createTempSync('tina-empty-');
      try {
        final bare = RegionRegistry(projectRoot: empty.path);
        final r = await ListRegionsTool(bare).execute({});
        expect(r.content, contains('No regions'));
      } finally {
        empty.deleteSync(recursive: true);
      }
    });
  });

  group('read_summary', () {
    test('returns the full summary with freshness', () async {
      final r = await ReadSummaryTool(regions).execute({'region': 'lib'});
      expect(r.isError, isFalse);
      expect(r.content,contains('# lib'));
      expect(r.content,contains('lib does X'));
      expect(r.content,contains('Current as of'));
    });

    test('unknown region errors with the available list', () async {
      final r = await ReadSummaryTool(regions).execute({'region': 'nope'});
      expect(r.isError, isTrue);
      expect(r.content, contains('No region "nope"'));
      expect(r.content,contains('lib'));
    });
  });

  group('query_region', () {
    QueryRegionTool tool() => QueryRegionTool(regions, scheduler,
        parentReference: 'main/main-model');

    test('dispatches one read-only agent primed with the region summary',
        () async {
      final r = await tool().execute({'region': 'lib', 'task': 'what is X?'});
      expect(r.isError, isFalse);
      expect(r.content,'report for what is X?');

      final call = scheduler.calls.single;
      expect(call.systemPrompt, contains('region agent for "lib"'));
      expect(call.systemPrompt, contains('lib does X'));
      expect(call.task, 'what is X?');
      expect(call.toolProfile, ToolProfile.readOnly);
      expect(call.includeDelegate, isFalse);
      // No allocation model on lib, no input override → inherit the main model.
      expect(call.modelReference, isNull);
    });

    test('an input model override wins over the region allocation', () async {
      final r = await tool().execute({
        'region': 'lib/src',
        'task': 'go',
        'llm_provider': 'deepseek',
        'llm_model': 'deepseek-chat',
      });
      expect(r.isError, isFalse);
      expect(scheduler.calls.single.modelReference, 'deepseek/deepseek-chat');
    });

    test('a region with an allocated model inherits it', () async {
      await tool().execute({'region': 'lib/src', 'task': 'go'});
      expect(scheduler.calls.single.modelReference, 'fast/fast-model');
    });

    test('unknown region errors', () async {
      final r = await tool().execute({'region': 'nope', 'task': 'go'});
      expect(r.isError, isTrue);
      expect(r.content, contains('No region "nope"'));
      expect(scheduler.calls, isEmpty);
    });
  });

  group('broadcast_region', () {
    test('fans out to every region and merges the reports', () async {
      final r = await BroadcastRegionTool(regions, scheduler,
              parentReference: 'main/main-model')
          .execute({'task': 'who owns feature X?'});
      expect(r.isError, isFalse);
      expect(r.content,contains('### lib'));
      expect(r.content,contains('### lib/src'));
      expect(r.content,contains('report for who owns feature X?'));
      expect(scheduler.calls.length, 2);
    });
  });

  group('allocate_region / forget_region', () {
    test('allocate writes the allocation and fires a single-dir refresh',
        () async {
      final idx = _StubIndex();
      final r = await AllocateRegionTool(regions, idx)
          .execute({'dir': 'lib/src'});
      expect(r.isError, isFalse);
      expect(r.content,contains('Allocated'));
      // The unawaited refresh lands on the next microtask.
      await Future<void>.delayed(Duration.zero);
      expect(idx.refreshes, 1);
      expect(idx.lastDirs, ['lib/src']);
      expect(regions.find('lib/src'), isNotNull);
    });

    test('allocate refuses a missing directory without refreshing', () async {
      final idx = _StubIndex();
      final r = await AllocateRegionTool(regions, idx).execute({'dir': 'nope'});
      expect(r.isError, isTrue);
      expect(r.content, contains('No such directory'));
      expect(idx.refreshes, 0);
    });

    test('forget removes the region', () async {
      final r = await ForgetRegionTool(regions).execute({'dir': 'lib/src'});
      expect(r.isError, isFalse);
      expect(regions.find('lib/src'), isNull);
    });
  });
}
