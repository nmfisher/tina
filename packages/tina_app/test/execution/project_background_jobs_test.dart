import 'package:tina_app/src/execution/background_job_supervisor.dart';
import 'package:tina_app/src/execution/project_background_jobs.dart';
import 'package:tina_app/src/session/conversation.dart';
import 'package:tina_app/src/summaries/summary_index.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// The background /index fleet must run on the conversation's PROVEN model
/// ref (persisted meta, else the session provider + live model) — never the
/// config default, which can name a model the provider cannot serve (every
/// request then 404s and the run dies as unfinished nodes).
void main() {
  late FakeHostInterface host;
  late FakeProvider provider;
  late Conversation conv;

  setUp(() {
    host = FakeHostInterface();
    provider = FakeProvider(const []);
    conv = Conversation(
      id: 'c1',
      label: 'main',
      agent: Agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        system: '',
      ),
      provider: provider,
      host: host,
      policy: PermissionPolicy(),
    );
  });

  test('runIndex threads modelRefOf(conv) into the summary refresh',
      () async {
    String? lastModelRef;
    final idx = _StubSummaryIndex(onRefresh: (modelRef) {
      lastModelRef = modelRef;
      return const SummaryIndexResult(
        status: SummaryIndexStatus(
          totalDirs: 1,
          staleDirs: [],
          deletedDirs: [],
          headSha: 'zzz9998',
          firstRun: false,
          hasAllocations: false,
        ),
        regenerated: 1,
        regeneratedDirs: ['lib'],
        deletedDirs: [],
      );
    });
    final jobs = ProjectBackgroundJobs(
      supervisor: BackgroundJobSupervisor(),
      summaryIndex: () => idx,
      persistUsage: (_) async {},
      modelRefOf: (conv) => 'nim/existing-model',
    );

    await jobs.runIndex(conv, null);

    // The job is async; wait for the supervisor slot to drain.
    while (jobs.isIndexRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(idx.refreshCalls, 1);
    expect(lastModelRef, 'nim/existing-model');
  });
}

class _StubSummaryIndex implements SummaryIndex {
  _StubSummaryIndex({required this.onRefresh});

  final SummaryIndexResult Function(String? modelRef) onRefresh;
  int refreshCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<SummaryIndexResult> refresh({
    bool repartition = false,
    bool dryRun = false,
    List<String>? dirs,
    HostInterface? host,
    String? modelRef,
    Future<void>? cancelSignal,
  }) async {
    refreshCalls++;
    return onRefresh(modelRef);
  }
}
