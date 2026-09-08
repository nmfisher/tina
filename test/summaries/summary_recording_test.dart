import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/application/project_execution.dart';
import 'package:tina/environment/file_environment_repository.dart';
import 'package:tina/summaries/git_summary_repository.dart';
import 'package:tina/summaries/sidecar_repo.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina/summaries/summary_repository.dart';
import 'package:tina_engine/tina_engine.dart';
import 'fleet_test_harness.dart';

class _Fleet implements SummaryFleet {
  final void Function() execute;
  _Fleet(this.execute);
  @override
  Future<SpendLedger> run(SummaryPlan plan, RunInteraction interaction) async {
    execute();
    return SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
  }
}

void main() {
  late Directory temp;
  late Directory project;
  late SidecarSummaryRepo sidecar;
  late GitSummaryRepository repository;
  setUp(() {
    final fixture = buildTempProject();
    temp = fixture.tempRoot;
    project = fixture.project;
    sidecar = SidecarSummaryRepo(
      root: fixture.sidecarRoot,
      projectRoot: project,
    );
    repository = GitSummaryRepository(
      sidecar: sidecar,
      environment: FileEnvironmentRepository(projectRoot: project.path),
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));
  test(
    'recording stamps the post-run HEAD when HEAD changes during execution',
    () async {
      final old = sidecar.headCommit();
      final service = SummaryIndex(
        repository: repository,
        fleet: _Fleet(() {
          File(
            '${project.path}/.tina/summaries/lib.md',
          ).writeAsStringSync('summary at $old');
          File(
            '${project.path}/lib/a.dart',
          ).writeAsStringSync('changed during fleet');
          git(project, ['add', 'lib']);
          git(project, ['commit', '-m', 'during fleet']);
        }),
      );
      final result = await service.refresh();
      expect(sidecar.headCommit(), isNot(old));
      expect(sidecar.loadManifest().dirs['lib']!.commit, sidecar.headCommit());
      expect(sidecar.readSummary('lib'), 'summary at $old');
      expect(result.status.staleDirs, isNot(contains('lib')));
    },
  );
  test(
    'existing summary file satisfies historical file-presence verification',
    () async {
      final projectHead = sidecar.headCommit();
      repository.prepare();
      File(
        '${project.path}/.tina/summaries/lib.md',
      ).writeAsStringSync('old summary');
      final service = SummaryIndex(
        repository: repository,
        fleet: _Fleet(() {}),
      );
      final result = await service.refresh();
      expect(result.regeneratedDirs, contains('lib'));
      expect(sidecar.loadManifest().dirs['lib'], isNotNull);
      expect(
        sidecar.headCommit(),
        projectHead,
        reason: 'sidecar commits must not change the project',
      );
      expect(
        Directory('${project.path}/.tina/summaries/.git').existsSync(),
        isTrue,
      );
    },
  );
  test('inspection and dry-run do not create the sidecar', () async {
    final service = SummaryIndex(
      repository: repository,
      fleet: _Fleet(() {
        fail('dry-run executed');
      }),
    );
    await service.status();
    await service.refresh(dryRun: true);
    expect(Directory('${project.path}/.tina/summaries').existsSync(), isFalse);
  });
}
