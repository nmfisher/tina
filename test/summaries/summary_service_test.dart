import 'dart:async';
import 'package:test/test.dart';
import 'package:tina/application/project_execution.dart';
import 'package:tina/summaries/summary_index.dart';
import 'package:tina/summaries/summary_models.dart';
import 'package:tina/summaries/summary_repository.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_host_interface.dart';

class MemorySummaries implements SummaryRepository {
  final events = <String>[];
  List<String> partition = ['lib', 'test'];
  final recorded = <String>{};
  final files = <String>{};
  bool allocated = false;
  bool failRecord = false;
  @override
  bool proposalShown = false;
  @override
  void markProposalShown() => proposalShown = true;
  @override
  SummarySnapshot inspect() {
    events.add('inspect');
    final stale = partition.where((d) => !recorded.contains(d)).toList();
    return SummarySnapshot(
      manifest: SummaryManifest(
        dirs: {
          for (final d in recorded)
            d: const DirSummary(
              commit: 'head',
              tree: 'tree',
              file: 'summary.md',
            ),
        },
      ),
      status: SummaryIndexStatus(
        totalDirs: partition.length,
        staleDirs: stale,
        deletedDirs: recorded.where((d) => !partition.contains(d)).toList(),
        headSha: 'head',
        firstRun: recorded.isEmpty,
        hasAllocations: allocated,
      ),
      repartitioned: StaleSet(toRegenerate: List.of(partition), deleted: []),
    );
  }

  @override
  void prepare() => events.add('prepare');
  @override
  List<String> record(SummaryPlan plan) {
    events.add('record');
    if (failRecord) throw StateError('commit failed');
    if (plan.repartition) recorded.clear();
    final landed = plan.work.toRegenerate.where(files.contains).toList();
    recorded.addAll(landed);
    recorded.removeAll(plan.work.deleted);
    files.removeAll(plan.work.deleted);
    return landed;
  }
}

class FakeFleet implements SummaryFleet {
  final MemorySummaries repository;
  Future<void> Function(SummaryPlan, RunInteraction)? execute;
  FakeFleet(this.repository);
  @override
  Future<SpendLedger> run(SummaryPlan plan, RunInteraction interaction) async {
    repository.events.add('run');
    await execute?.call(plan, interaction);
    return SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0)
      ..record(const TokenUsage(inputTokens: 10, outputTokens: 5));
  }
}

void main() {
  late MemorySummaries repository;
  late FakeFleet fleet;
  late SpendLedger spend;
  late SummaryIndex service;
  setUp(() {
    repository = MemorySummaries();
    fleet = FakeFleet(repository);
    spend = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
    service = SummaryIndex(
      repository: repository,
      fleet: fleet,
      spendLedger: spend,
    );
  });
  test('first run plans work and records only delivered files', () async {
    fleet.execute = (plan, _) async {
      expect(plan.work.toRegenerate, ['lib', 'test']);
      repository.files.add('lib');
    };
    final result = await service.refresh();
    expect(result.regeneratedDirs, ['lib']);
    expect(result.status.staleDirs, ['test']);
    expect(spend.totalTokens, 15);
    expect(repository.events, [
      'inspect',
      'prepare',
      'run',
      'record',
      'inspect',
    ]);
  });
  test('unchanged state skips execution and storage initialization', () async {
    repository.recorded.addAll(repository.partition);
    final result = await service.refresh();
    expect(result.planned.isEmpty, isTrue);
    expect(repository.events, ['inspect', 'inspect']);
    expect(spend.totalTokens, 0);
  });
  test('dry run reports work without writes or model execution', () async {
    final result = await service.refresh(dryRun: true);
    expect(result.planned.toRegenerate, ['lib', 'test']);
    expect(result.regenerated, 0);
    expect(repository.events, ['inspect', 'inspect']);
  });
  test('restricted regeneration keeps deletions outside the filter', () async {
    repository.recorded.add('old');
    repository.files.addAll(['old', 'lib']);
    final result = await service.refresh(dirs: ['lib']);
    expect(result.planned.toRegenerate, ['lib']);
    expect(result.deletedDirs, ['old']);
    expect(repository.recorded, {'lib'});
    expect(repository.files, {'lib'});
    expect(result.status.staleDirs, ['test']);
  });
  test('allocated partition replaces defaults in the inspected plan', () async {
    repository.partition = ['lib/src'];
    repository.allocated = true;
    final result = await service.refresh(dryRun: true);
    expect(result.planned.toRegenerate, ['lib/src']);
    expect(result.status.hasAllocations, isTrue);
  });
  test(
    'repartition uses empty-manifest work and honors restrictions',
    () async {
      repository.recorded.addAll(['lib', 'test', 'old']);
      repository.files.addAll(['lib', 'test', 'old']);
      final result = await service.refresh(repartition: true, dirs: ['lib']);
      expect(result.planned.toRegenerate, ['lib']);
      // Preserve existing reset semantics: old keys are forgotten, not deleted.
      expect(result.deletedDirs, isEmpty);
      expect(repository.recorded, {'lib'});
      expect(repository.files, contains('old'));
      expect(result.status.staleDirs, ['test']);
    },
  );
  test(
    'empty repartition still executes and records a cleared manifest',
    () async {
      repository.partition = [];
      repository.recorded.add('old');
      await service.refresh(repartition: true);
      expect(
        repository.events,
        containsAllInOrder(['prepare', 'run', 'record']),
      );
      expect(repository.recorded, isEmpty);
    },
  );
  test('missing writes remain stale after a completed fleet', () async {
    final result = await service.refresh();
    expect(result.regenerated, 0);
    expect(result.status.staleDirs, ['lib', 'test']);
  });
  test(
    'cancelled fleet can record partial writes and merges settled usage',
    () async {
      final cancel = Completer<void>()..complete();
      final host = FakeHostInterface();
      fleet.execute = (_, interaction) async {
        expect(interaction.host, same(host));
        expect(interaction.cancelSignal, same(cancel.future));
        await interaction.cancelSignal;
        repository.files.add('lib');
      };
      final result = await service.refresh(
        host: host,
        cancelSignal: cancel.future,
      );
      expect(result.status.staleDirs, ['test']);
      expect(spend.totalTokens, 15);
    },
  );
  test(
    'thrown execution leaves tracking and session spend unchanged',
    () async {
      fleet.execute = (_, __) async {
        throw StateError('execution');
      };
      await expectLater(service.refresh(), throwsStateError);
      expect(repository.events, ['inspect', 'prepare', 'run']);
      expect(repository.recorded, isEmpty);
      expect(spend.totalTokens, 0);
    },
  );
  test('record failure remains visible and skips spend merge', () async {
    repository.failRecord = true;
    await expectLater(service.refresh(), throwsStateError);
    expect(spend.totalTokens, 0);
  });
  test(
    'inspection requires only a repository and persists the proposal marker',
    () async {
      final inspection = SummaryInspection(repository: repository);
      expect((await inspection.status()).firstRun, isTrue);
      inspection.markProposalShown();
      expect(inspection.proposalShown, isTrue);
    },
  );
}
