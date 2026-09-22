import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/platform/environment.dart';
import 'package:tina_app/src/summaries/allocations_store.dart';
import 'package:tina_app/src/summaries/sidecar_repo.dart';
import 'package:tina_app/src/summaries/git_summary_repository.dart';
import 'package:tina_app/src/summaries/summary_index.dart';
import 'package:tina_app/src/summaries/summary_runner.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';

SummaryInspection buildSummaryInspection({
  required String workspaceRoot,
  AllocationsStore? allocations,
}) =>
    SummaryInspection(repository: _summaryRepository(workspaceRoot, allocations));

GitSummaryRepository _summaryRepository(
  String project,
  AllocationsStore? allocations, [
  List<String>? partition,
]) => GitSummaryRepository(
  sidecar: SidecarSummaryRepo(
    root: Directory('$project/.tina'),
    workspaceRoot: Directory(project),
  ),
  allocations: allocations,
  partition: partition,
);

SummaryIndex buildSummaryIndex({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  required String workspaceRoot,
  Environment? environment,
  WorkspaceToolScope? toolScope,
  PromptContext? promptContext,
  AllocationsStore? allocations,
  SpendLedger? spendLedger,
  List<String>? partition,
}) {
  workspaceRoot = p.normalize(p.absolute(workspaceRoot));
  return SummaryIndex(
    repository: _summaryRepository(workspaceRoot, allocations, partition),
    fleet: SummaryRunner(
      config: config,
      executionFactory: () => buildExecutionRuntime(
        config: config,
        registry: registry,
        environment: environment,
        workspaceRoot: workspaceRoot,
        toolScope: toolScope,
        promptContext: promptContext,
      ),
    ),
    spendLedger: spendLedger,
  );
}

/// Standalone adapter binds run options at composition, never inside services.
class WorkspaceServiceRun<T> {
  final Future<T> Function() run;
  WorkspaceServiceRun(this.run);
}

WorkspaceServiceRun<StaleSet> buildSummaryRun({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  required String workspaceRoot,
  Environment? environment,
  WorkspaceToolScope? toolScope,
  PromptContext? promptContext,
  SpendLedger? spendLedger,
  bool dryRun = false,
  bool repartition = false,
  List<String>? dirs,
  List<String>? partition,
  HostInterface? host,
  Future<void>? cancelSignal,
}) {
  final service = buildSummaryIndex(
    config: config,
    registry: registry,
    workspaceRoot: workspaceRoot,
    environment: environment,
    toolScope: toolScope,
    promptContext: promptContext,
    spendLedger: spendLedger,
    partition: partition,
  );
  return WorkspaceServiceRun(
    () async => (await service.refresh(
      dryRun: dryRun,
      repartition: repartition,
      dirs: dirs,
      host: host,
      cancelSignal: cancelSignal,
    )).planned,
  );
}
