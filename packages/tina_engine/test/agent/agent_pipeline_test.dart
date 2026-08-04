import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_tool.dart';

void main() {
  group('AgentPipeline lookups', () {
    final research = AgentRole(name: 'research', description: 'explore');
    final qa = Workflow(
      name: 'qa',
      description: 'pipeline',
      stages: [WorkflowStage(target: research, task: 'go')],
    );
    final pipeline = AgentPipeline(
      mainRole: const AgentRole(name: 'main', description: 'main'),
      roles: [research],
      workflows: [qa],
    );

    test('role() finds a sub-agent role; main is not a role', () {
      expect(pipeline.role('research')?.description, 'explore');
      expect(pipeline.role('main'), isNull); // main is mainRole, not in roles
      expect(pipeline.role('nope'), isNull);
    });

    test('workflow() finds a workflow', () {
      expect(pipeline.workflow('qa')?.description, 'pipeline');
      expect(pipeline.workflow('research'), isNull); // it's a role
    });

    test('target() resolves a role or workflow name (runtime lookup)', () {
      expect(pipeline.target('research')?.name, 'research');
      expect(pipeline.target('qa')?.name, 'qa');
      expect(pipeline.target('nope'), isNull);
    });

    test('delegateTargets lists roles + workflows, never main', () {
      final names = pipeline.delegateTargets.map((t) => t.name).toSet();
      expect(names, containsAll(['research', 'qa']));
      expect(names, isNot(contains('main')));
    });
  });

  group('Workflow', () {
    final verifier = AgentRole(name: 'verifier', description: 'v');

    test('WorkflowStage carries target, task, id, dependsOn, haltOnFail', () {
      final stage = WorkflowStage(target: verifier, task: 'review');
      expect(stage.target, same(verifier));
      expect(stage.task, 'review');
      expect(stage.id, isNull);
      expect(stage.dependsOn, isNull);
      expect(stage.haltOnFail, isFalse); // defaults off

      final named = WorkflowStage(
          id: 'v',
          target: verifier,
          task: 'review',
          dependsOn: ['impl'],
          haltOnFail: true);
      expect(named.id, 'v');
      expect(named.dependsOn, ['impl']);
      expect(named.haltOnFail, isTrue);
    });

    test('a workflow is constructible with an ordered stage list', () {
      final implementer = AgentRole(name: 'implementer', description: 'i');
      final tester = AgentRole(name: 'tester', description: 't');
      final workflow = Workflow(
        name: 'qa',
        description: 'implement → verify → test',
        stages: [
          WorkflowStage(target: implementer, task: 'Implement.'),
          WorkflowStage(target: verifier, task: 'Review.', haltOnFail: true),
          WorkflowStage(target: tester, task: 'Test.'),
        ],
      );
      expect(workflow.stages, hasLength(3));
      // Targets are direct references — order preserved.
      expect(workflow.stages.map((s) => s.target.name),
          ['implementer', 'verifier', 'tester']);
    });
  });

  group('stripForSafeMode (--safe-mode)', () {
    test('drops write/edit/bash, keeps the read-only tools', () {
      final tools = [
        FakeTool.noOp('read'),
        FakeTool.noOp('write'),
        FakeTool.noOp('edit'),
        FakeTool.noOp('bash'),
        FakeTool.noOp('grep'),
        FakeTool.noOp('glob'),
        FakeTool.noOp('search'),
      ];
      final stripped =
          stripForSafeMode(tools).map((t) => t.schema.name).toSet();
      expect(stripped, containsAll(['read', 'grep', 'glob', 'search']));
      expect(stripped, isNot(containsAll(['write', 'edit', 'bash'])));
      expect(stripped.intersection(kSafeModeDisabledTools), isEmpty);
    });

    test('leaves a read-only-only set unchanged', () {
      final tools = [FakeTool.noOp('read'), FakeTool.noOp('grep')];
      final stripped =
          stripForSafeMode(tools).map((t) => t.schema.name).toSet();
      expect(stripped, ['read', 'grep']);
    });

    test('safe-mode drops the shared tool singletons by name', () {
      // The default pipeline's implementer declares read/write/edit/bash: under
      // safe-mode only read should survive.
      final implementer = defaultPipeline.role('implementer')!;
      final stripped =
          stripForSafeMode(implementer.tools).map((t) => t.schema.name).toSet();
      expect(stripped, contains('read'));
      expect(stripped.intersection(kSafeModeDisabledTools), isEmpty);
    });
  });

  group('AgentRole fields', () {
    test('modelTier and tools default; canDelegate defaults false', () {
      const role = AgentRole(name: 'research', description: 'd');
      expect(role.modelTier, isNull);
      expect(role.tools, isEmpty);
      expect(role.canDelegate, isFalse);
      expect(role.promptIdentity, '');
    });

    test('carries a model tier, tool set, and canDelegate', () {
      final read = FakeTool.noOp('read');
      final bash = FakeTool.noOp('bash');
      final role = AgentRole(
        name: 'coder',
        description: 'd',
        modelTier: 'heavy',
        tools: {read, bash},
        canDelegate: true,
      );
      expect(role.modelTier, 'heavy');
      expect(
          role.tools.map((t) => t.schema.name), containsAll(['read', 'bash']));
      expect(role.canDelegate, isTrue);
    });
  });
}
