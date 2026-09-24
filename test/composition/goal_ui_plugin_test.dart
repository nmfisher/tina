import 'package:test/test.dart';
import 'package:tina/composition/goal_ui.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';

/// Mirrors plan_ui_plugin_test.dart: the release-failure regression the plan
/// plugin hit (factory + declared `provides` double-bind) applies verbatim to
/// the goal plugin, so the same activation tests run against it — plus the
/// command, middleware-injection, and judge-hook contracts.
void main() {
  test('goalUiPlugin activates in a PluginRuntime and provides the store', () {
    final store = GoalStore();
    final runtime = PluginRuntime(
      name: 'goal-ui-test',
      plugins: [goalUiPlugin(store: store)],
    )..activateSync();
    addTearDown(runtime.dispose);

    expect(runtime.stateOf('tina.goal'), PluginLifecycleState.active);
    expect(runtime.scope.lookup(goalStoreServiceKey), same(store));
  });

  test('the store works end-to-end through the activated scope', () {
    final store = GoalStore();
    final runtime = PluginRuntime(
      name: 'goal-ui-e2e-test',
      plugins: [goalUiPlugin(store: store)],
    )..activateSync();
    addTearDown(runtime.dispose);

    final fromScope = runtime.scope.lookup(goalStoreServiceKey)!;
    fromScope.set('c1', 'fix the login race');
    expect(store.read('c1').text, 'fix the login race');
    expect(identical(fromScope, store), isTrue);
  });

  group('/goal command', () {
    Future<(
      GoalStore,
      PluginRuntime,
      CommandRegistry,
      FakeHostInterface,
    )> wired() async {
      final store = GoalStore();
      final runtime = PluginRuntime(
        name: 'goal-command-test',
        plugins: [goalUiPlugin(store: store)],
      )..activateSync();
      final registry = CommandRegistry(runtime.scope);
      return (store, runtime, registry, FakeHostInterface());
    }

    test('set stores the goal and echoes it', () async {
      final (store, runtime, registry, host) = await wired();
      addTearDown(runtime.dispose);

      final result = await registry.dispatch(
        '/goal fix the login race',
        host: host,
        conversationId: 'c1',
      );
      expect(result, isA<CmdHandled>());
      expect(store.read('c1').text, 'fix the login race');
      expect(host.messages.join(), contains('Goal: fix the login race'));
      store.dispose();
    });

    test('bare /goal shows the goal; /goal clear removes it', () async {
      final (store, runtime, registry, host) = await wired();
      addTearDown(runtime.dispose);

      await registry.dispatch('/goal write the docs', host: host,
          conversationId: 'c1');
      await registry.dispatch('/goal', host: host, conversationId: 'c1');
      expect(host.messages.last, contains('write the docs'));
      expect(host.messages.last, contains('not judged yet'));

      await registry.dispatch('/goal clear', host: host, conversationId: 'c1');
      expect(store.read('c1').isEmpty, isTrue);
      expect(host.messages.last, contains('Goal cleared.'));
      store.dispose();
    });

    test('/goal check without a judge reports and fails cleanly', () async {
      final (store, runtime, registry, host) = await wired();
      addTearDown(runtime.dispose);

      await registry.dispatch('/goal a goal', host: host,
          conversationId: 'c1');
      final result = await registry
          .dispatch('/goal check', host: host, conversationId: 'c1');
      final handled = result as CmdHandled;
      expect(handled.failed, isTrue);
      expect(host.messages.last, contains('No goal judge is wired'));
      expect(store.read('c1').hasVerdict, isFalse);
      store.dispose();
    });

    test('/goal check runs the late-bound judge hook and records the verdict',
        () async {
      final (store, runtime, registry, host) = await wired();
      addTearDown(runtime.dispose);

      store.judgeHook = (conversationId, {force = false}) async {
        expect(force, isTrue);
        store.recordVerdict(conversationId, GoalVerdict.achieved,
            'the failing test now passes');
        return GoalVerdict.achieved;
      };
      await registry.dispatch('/goal fix the bug', host: host,
          conversationId: 'c1');
      final result = await registry
          .dispatch('/goal check', host: host, conversationId: 'c1');
      expect(result, isA<CmdHandled>());
      final echo = host.messages.last;
      expect(echo, contains('ACHIEVED'));
      expect(echo, contains('the failing test now passes'));
      store.dispose();
    });

    test('over-long goal text is rejected with a message', () async {
      final (store, runtime, registry, host) = await wired();
      addTearDown(runtime.dispose);

      final result = await registry.dispatch(
        '/goal ${'x' * (GoalStore.maxTextLength + 1)}',
        host: host,
        conversationId: 'c1',
      );
      expect((result as CmdHandled).failed, isTrue);
      expect(store.read('c1').isEmpty, isTrue);
      expect(host.messages.last, contains('exceeds'));
      store.dispose();
    });
  });

  group('GoalMiddleware', () {
    AgentContext context() => AgentContext(
          stage: AgentStage.request,
          cwd: '/tmp',
          loadWorkspaceContext: false,
          model: 'test/model',
        );

    final request = AgentRequest(
      system: 'base system',
      messages: const [],
      tools: const [],
    );

    test('appends the goal section to the system prompt at request stage',
        () async {
      final store = GoalStore()..set('c1', 'fix the login race');
      final decision = await GoalMiddleware(store, 'c1')
          .beforeRequest(context(), request);
      final system = decision.value!.system;
      expect(system, startsWith('base system'));
      expect(system, contains('<current-goal>'));
      expect(system, contains('Goal: fix the login race'));
      expect(system, contains('</current-goal>'));
      store.dispose();
    });

    test('injects the last verdict alongside the goal', () async {
      final store = GoalStore()
        ..set('c1', 'fix the login race')
        ..recordVerdict('c1', GoalVerdict.achieved, 'regression test added');
      final decision = await GoalMiddleware(store, 'c1')
          .beforeRequest(context(), request);
      expect(decision.value!.system, contains('ACHIEVED'));
      expect(decision.value!.system, contains('regression test added'));
      store.dispose();
    });

    test('passes the request through untouched without a goal', () async {
      final store = GoalStore();
      final decision = await GoalMiddleware(store, 'c1')
          .beforeRequest(context(), request);
      expect(decision.value!.system, 'base system');
      store.dispose();
    });

    test('is conversation-scoped: another conversation sees no goal', () async {
      final store = GoalStore()..set('c1', 'c1 goal');
      final decision = await GoalMiddleware(store, 'c2')
          .beforeRequest(context(), request);
      expect(decision.value!.system, 'base system');
      store.dispose();
    });
  });

  group('GoalStatusSource', () {
    test('declines empty goals and exposes summaries otherwise', () {
      final store = GoalStore();
      final source = GoalStatusSource(store);
      expect(source.read('c1'), isNull);
      store.set('c1', 'ship it');
      final summary = source.read('c1') as GoalSummary;
      expect(summary.text, 'ship it');
      expect(summary.verdict, GoalVerdict.none);
      store.recordVerdict('c1', GoalVerdict.uncertain, 'thin evidence');
      expect((source.read('c1') as GoalSummary).isUncertain, isTrue);
      store.dispose();
    });
  });
}
