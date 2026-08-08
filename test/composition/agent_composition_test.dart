import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/composition/agent_composition.dart';
import 'package:tina/config.dart';
import 'package:tina/pipeline/workflow_supervisor.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

/// Pins the composition wiring: `createScheduler` over the default pipeline,
/// and `buildAgent`'s interactive/headless split. Both modes share the full
/// file/shell tool set; interactive layers on delegate + channels + image
/// rendering, and the workflow surface (`launch_workflow` + `stop_workflow`)
/// is added in either mode when a [WorkflowSupervisor] is wired.
void main() {
  Config testConfig() => Config.parse(const ['--backend', 'ansi']);

  // A run seam that never actually runs a workflow — the tool-set tests don't
  // invoke it; they only assert it lands in the registry.
  RunWorkflow noopRun({Outcome outcome = const Outcome.success()}) =>
      ({required workflowName, required sink, input, history, cancelSignal,
          onEvent}) async => outcome;

  // A supervisor over the noop run; wired into buildAgent below.
  WorkflowSupervisor noopSupervisor() => WorkflowSupervisor(run: noopRun());

  group('buildAgent main tool set', () {
    test('interactive main gets full file tools + delegate + channels', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final agent = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config, // withSubAgents defaults true
      );
      // Full file/shell tool set is now present in interactive mode too.
      for (final t in ['read', 'write', 'edit', 'bash', 'search', 'grep', 'glob']) {
        expect(agent.tools[t], isNotNull, reason: t);
      }
      // Plus the orchestration surface.
      for (final t in ['delegate', 'send', 'receive', 'close', 'render_image']) {
        expect(agent.tools[t], isNotNull, reason: t);
      }
      // No supervisor wired → no workflow surface.
      expect(agent.tools['launch_workflow'], isNull);
      expect(agent.tools['stop_workflow'], isNull);
    });

    test('headless main gets the full base set, no delegate/channels', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final agent = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
        withSubAgents: false,
      );
      for (final t in ['read', 'write', 'edit', 'bash', 'search', 'grep', 'glob']) {
        expect(agent.tools[t], isNotNull, reason: t);
      }
      expect(agent.tools['delegate'], isNull);
      expect(agent.tools['send'], isNull);
    });

    test('the workflow surface is wired in both modes when a supervisor is '
        'provided', () {
      final config = testConfig();
      final scheduler = createScheduler(
        config: config,
        registry: ProviderRegistry(env: {}),
        pipeline: defaultPipeline,
      );
      final interactive = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c1',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
        supervisor: noopSupervisor(),
      );
      final headless = buildAgent(
        pipeline: defaultPipeline,
        scheduler: scheduler,
        conversationId: 'c2',
        provider: FakeProvider(const [], model: 'm'),
        host: FakeHostInterface(),
        policy: config.buildPolicy(),
        config: config,
        withSubAgents: false,
        supervisor: noopSupervisor(),
      );
      expect(interactive.tools['launch_workflow'], isNotNull);
      expect(interactive.tools['stop_workflow'], isNotNull);
      expect(headless.tools['launch_workflow'], isNotNull);
      expect(headless.tools['stop_workflow'], isNotNull);
    });
  });
}
