import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_provider.dart';

void main() {
  final pipeline = defaultTestPipeline(rolesHaveModelTiers: true);

  SubAgentScheduler sched(ProviderRegistry r, {required AgentPipeline p}) =>
      testScheduler(r, pipeline: p, modelTiers: defaultTestTiers);

  test('schema name is "delegate" and enum lists the pipeline roles', () {
    final scheduler =
        sched(scriptedRegistry({'a': answerEvents('x')}), p: pipeline);
    final tool = DelegateTool(testContext(scheduler, pipeline: pipeline));
    expect(tool.schema.name, 'delegate');
    final agentProp =
        (tool.schema.inputSchema['properties'] as Map)['delegations'] as Map;
    final itemAgent =
        ((agentProp['items'] as Map)['properties'] as Map)['agent'] as Map;
    expect(itemAgent['enum'], containsAll(['a', 'b']));
    // main is never delegatable.
    expect(itemAgent['enum'], isNot(contains('main')));
  });

  test('fan-out awaits all agents and merges their answers', () async {
    final scheduler = sched(
      scriptedRegistry(
          {'a': answerEvents('from-a'), 'b': answerEvents('from-b')}),
      p: pipeline,
    );
    final tool = DelegateTool(testContext(scheduler, pipeline: pipeline));

    final res = await tool.execute({
      'delegations': [
        {'agent': 'a', 'task': 't1'},
        {'agent': 'b', 'task': 't2'},
      ],
    });

    expect(res.isError, isFalse);
    expect(res.content, contains('### a\nfrom-a'));
    expect(res.content, contains('### b\nfrom-b'));
    await scheduler.dispose();
  });

  test('an unknown agent name yields an error result', () async {
    final scheduler =
        sched(scriptedRegistry({'a': answerEvents('x')}), p: pipeline);
    final tool = DelegateTool(testContext(scheduler, pipeline: pipeline));

    final res = await tool.execute({
      'delegations': [
        {'agent': 'nope', 'task': 't'},
      ],
    });
    expect(res.isError, isTrue);
    expect(res.content, contains('unknown agent "nope"'));
    await scheduler.dispose();
  });

  test('delegating to a workflow returns its final stage output', () async {
    final implementer =
        AgentRole(name: 'implementer', description: 'd', modelTier: 'a');
    final tester = AgentRole(name: 'tester', description: 'd', modelTier: 'b');
    final qa = Workflow(
      name: 'qa',
      description: 'implement → test',
      stages: [
        WorkflowStage(target: implementer, task: 'Implement.'),
        WorkflowStage(target: tester, task: 'Test.'),
      ],
    );
    final compositePipeline = defaultTestPipeline(
      extraRoles: [implementer, tester],
      workflows: [qa],
      rolesHaveModelTiers: true,
    );
    final scheduler = sched(
      scriptedRegistry(
          {'a': answerEvents('impl'), 'b': answerEvents('tested')}),
      p: compositePipeline,
    );
    final tool =
        DelegateTool(testContext(scheduler, pipeline: compositePipeline));

    final res = await tool.execute({
      'delegations': [
        {'agent': 'qa', 'task': 'build it'},
      ],
    });

    expect(res.isError, isFalse);
    expect(res.content, contains('### qa'));
    expect(res.content, contains('tested')); // final stage's output
    await scheduler.dispose();
  });

  test('a main-turn cancel propagates to spawned jobs', () async {
    final gate = Completer<void>(); // never completed by us
    final r = ProviderRegistry(env: {'TEST_KEY': 'k'})
      ..register(ProviderDescriptor(
        id: 'a',
        name: 'a',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://a.test',
        builder: (c) => HoldProvider(gate: gate.future),
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1)
        },
      ));
    final scheduler = sched(r, p: pipeline);
    final tool = DelegateTool(testContext(scheduler, pipeline: pipeline));

    final cancel = Completer<void>();
    final future = tool.execute({
      'delegations': [
        {'agent': 'a', 'task': 'hold'},
      ],
    }, cancelSignal: cancel.future);

    await Future<void>.delayed(Duration.zero); // let the job start
    cancel.complete(); // main-turn ESC

    final res = await future.timeout(const Duration(seconds: 5));
    expect(res.isError, isTrue); // the job was cancelled → error result
    expect(scheduler.jobs.every((j) => j.status == SubAgentJobStatus.cancelled),
        isTrue);
    await scheduler.dispose();
  });
}
