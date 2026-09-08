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
import 'package:tina_app/src/environment/environment_index.dart';
import 'package:tina_app/src/environment/environment_runner.dart';
import 'package:tina_app/src/environment/file_environment_repository.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';

SummaryInspection buildSummaryInspection({
  required String projectRoot,
  AllocationsStore? allocations,
}) =>
    SummaryInspection(repository: _summaryRepository(projectRoot, allocations));

GitSummaryRepository _summaryRepository(
  String project,
  AllocationsStore? allocations, [
  List<String>? partition,
]) => GitSummaryRepository(
  sidecar: SidecarSummaryRepo(
    root: Directory('$project/.tina'),
    projectRoot: Directory(project),
  ),
  allocations: allocations,
  partition: partition,
  environment: FileEnvironmentRepository(projectRoot: project),
);

SummaryIndex buildSummaryIndex({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  required String projectRoot,
  Environment? environment,
  ProjectToolScope? toolScope,
  PromptContext? promptContext,
  AllocationsStore? allocations,
  SpendLedger? spendLedger,
  List<String>? partition,
}) {
  projectRoot = p.normalize(p.absolute(projectRoot));
  return SummaryIndex(
    repository: _summaryRepository(projectRoot, allocations, partition),
    fleet: SummaryRunner(
      config: config,
      executionFactory: () => buildExecutionRuntime(
        config: config,
        registry: registry,
        environment: environment,
        projectRoot: projectRoot,
        toolScope: toolScope,
        promptContext: promptContext,
      ),
    ),
    spendLedger: spendLedger,
  );
}

EnvironmentIndex buildEnvironmentIndex({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  required String projectRoot,
  Environment? environment,
  ProjectToolScope? toolScope,
  PromptContext? promptContext,
  SpendLedger? spendLedger,
}) {
  projectRoot = p.normalize(p.absolute(projectRoot));
  final repository = FileEnvironmentRepository(projectRoot: projectRoot);
  return EnvironmentIndex(
    repository: repository,
    spendLedger: spendLedger,
    runner: EnvironmentRunner(
      config: config,
      projectRoot: projectRoot,
      surveyFolders: repository.surveyFolders,
      executionFactory: () => buildExecutionRuntime(
        config: config,
        registry: registry,
        environment: environment,
        projectRoot: projectRoot,
        toolScope: toolScope,
        promptContext: promptContext,
      ),
    ),
  );
}

/// Standalone adapter binds run options at composition, never inside services.
class ProjectServiceRun<T> {
  final Future<T> Function() run;
  ProjectServiceRun(this.run);
}

ProjectServiceRun<StaleSet> buildSummaryRun({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  required String projectRoot,
  Environment? environment,
  ProjectToolScope? toolScope,
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
    projectRoot: projectRoot,
    environment: environment,
    toolScope: toolScope,
    promptContext: promptContext,
    spendLedger: spendLedger,
    partition: partition,
  );
  return ProjectServiceRun(
    () async => (await service.refresh(
      dryRun: dryRun,
      repartition: repartition,
      dirs: dirs,
      host: host,
      cancelSignal: cancelSignal,
    )).planned,
  );
}

ProjectServiceRun<bool> buildEnvironmentRun({
  required RuntimeConfig config,
  required ProviderRegistry registry,
  required String projectRoot,
  Environment? environment,
  ProjectToolScope? toolScope,
  PromptContext? promptContext,
  SpendLedger? spendLedger,
  HostInterface? host,
  Future<void>? cancelSignal,
  String? modelRef,
  PermissionAsker? asker,
  AgentSink Function(String dir)? scoutSinkFactory,
}) {
  final service = buildEnvironmentIndex(
    config: config,
    registry: registry,
    projectRoot: projectRoot,
    environment: environment,
    toolScope: toolScope,
    promptContext: promptContext,
    spendLedger: spendLedger,
  );
  return ProjectServiceRun(
    () => service.refresh(
      host: host,
      cancelSignal: cancelSignal,
      modelRef: modelRef,
      asker: asker,
      scoutSinkFactory: scoutSinkFactory,
    ),
  );
}
