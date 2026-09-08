import 'package:test/test.dart';
import 'package:tina_app/src/execution/project_execution.dart';
import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_app/src/summaries/summary_models.dart';
import 'package:tina_app/src/summaries/summary_repository.dart';
import 'package:tina_app/src/summaries/summary_runner.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_host_interface.dart';

class _FailingExecution implements ProjectExecution {
  int disposals = 0;
  final failure = StateError('provider build');
  @override
  LlmProvider buildStartupProvider() => throw failure;
  @override
  Future<void> dispose() async {
    disposals++;
    throw StateError('cleanup');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'injected execution is released on provider failure; host stays borrowed',
    () async {
      final execution = _FailingExecution();
      final host = FakeHostInterface();
      final runner = SummaryRunner(
        config: RuntimeConfig(),
        executionFactory: () async => execution,
      );
      const plan = SummaryPlan(
        manifest: SummaryManifest(dirs: {}),
        work: StaleSet(toRegenerate: ['lib'], deleted: []),
        repartition: false,
        dryRun: false,
      );
      await expectLater(
        runner.run(plan, RunInteraction(host: host)),
        throwsA(same(execution.failure)),
      );
      expect(execution.disposals, 1);
      expect(host.disposeCalls, 0);
      await host.dispose();
    },
  );
}
