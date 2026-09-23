import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';

/// Pins the plan plugin's four surfaces: the update_plan tool's decode
/// round-trip, the request middleware's `<current-plan>` injection, the strip
/// status source, and the /plan command's subcommands.
void main() {
  late PlanStore store;
  setUp(() {
    store = PlanStore();
  });
  tearDown(() {
    store.dispose();
  });

  AgentContext context(AgentStage stage) => AgentContext(
        stage: stage,
        cwd: '.',
        loadWorkspaceContext: false,
        model: 'test-model',
      );

  /// [PlanMiddleware] always continues; this pulls the (possibly rewritten)
  /// request back out of the decision.
  Future<AgentRequest> requestFor(PlanMiddleware middleware, AgentStage stage) async {
    final decision = await middleware.beforeRequest(
      context(stage),
      AgentRequest(system: 'base', messages: [], tools: []),
    );
    if (decision.action != AgentAction.next || decision.value == null) {
      fail('expected a next decision carrying a request');
    }
    return decision.value!;
  }

  group(PlanTool, () {
    test('replaces the conversation plan and reports success', () async {
      final tool = PlanTool(store, 'c1');
      final r = await tool.execute({
        'items': [
          {'text': '  fix renderer  ', 'state': 'done'},
          {'text': 'write tests', 'state': 'in_progress'},
        ],
      });
      expect(r.isError, isFalse);
      expect(r.content, 'Plan updated.');
      final plan = store.read('c1');
      expect(plan.items.map((i) => (i.text, i.state)).toList(), [
        ('fix renderer', PlanState.done),
        ('write tests', PlanState.inProgress),
      ]);
      expect(plan.summary, 'write tests 1/2');
    });

    test('an empty list clears the plan', () async {
      store.update('c1', [(text: 'a', state: PlanState.pending)]);
      final r = await PlanTool(store, 'c1').execute({'items': []});
      expect(r.isError, isFalse);
      expect(r.content, 'Plan cleared.');
      expect(store.read('c1').isEmpty, isTrue);
    });

    test('malformed items surface as tool errors, not throws', () async {
      final tool = PlanTool(store, 'c1');
      final cases = <Object?>[
        null,
        'nope',
        [
          {'state': 'done'}
        ],
        [
          {'text': 'no state'}
        ],
        [
          {'text': 'bad state', 'state': 'cancelled'}
        ],
      ];
      for (final items in cases) {
        final r = await tool.execute({'items': items});
        expect(r.isError, isTrue, reason: 'input: $items');
      }
      expect(store.read('c1').isEmpty, isTrue);
    });

    test('store invariant violations (two in-progress) become errors',
        () async {
      final r = await PlanTool(store, 'c1').execute({
        'items': [
          {'text': 'a', 'state': 'in_progress'},
          {'text': 'b', 'state': 'in_progress'},
        ],
      });
      expect(r.isError, isTrue);
      expect(r.content, contains('at most one'));
      expect(store.read('c1').isEmpty, isTrue);
    });

    test('writes are scoped to the tool\'s conversation', () async {
      await PlanTool(store, 'c1').execute({
        'items': [
          {'text': 'a', 'state': 'pending'},
        ],
      });
      expect(store.read('c2').isEmpty, isTrue);
    });

    test('the schema enumerates the three states and requires items', () {
      final schema = PlanTool(store, 'c1').schema;
      expect(schema.name, 'update_plan');
      expect(schema.inputSchema['type'], 'object');
      final itemSchema = ((schema.inputSchema['properties']
          as Map)['items'] as Map)['items'] as Map;
      expect(
        ((itemSchema['properties'] as Map)['state'] as Map)['enum'],
        ['pending', 'in_progress', 'done'],
      );
    });
  });

  group(PlanMiddleware, () {
    test('appends the plan section to the system prompt', () async {
      store.update('c1', [
        (text: 'ship it', state: PlanState.inProgress),
        (text: 'announce', state: PlanState.pending),
      ]);
      final req =
          await requestFor(PlanMiddleware(store, 'c1'), AgentStage.request);
      final system = req.system;
      expect(system, startsWith('base\n'));
      expect(system, contains('<current-plan>'));
      expect(system, contains('[~] ship it'));
      expect(system, contains('[ ] announce'));
      expect(system, contains('update_plan'));
      expect(system, endsWith('</current-plan>\n'));
    });

    test('an empty plan leaves the request untouched', () async {
      final system =
          await requestFor(PlanMiddleware(store, 'c1'), AgentStage.request);
      expect(system.system, 'base');
    });

    test('injects the building conversation\'s plan, not another\'s',
        () async {
      store.update('c1', [(text: 'mine', state: PlanState.pending)]);
      store.update('c2', [(text: 'theirs', state: PlanState.pending)]);
      final system =
          await requestFor(PlanMiddleware(store, 'c1'), AgentStage.request);
      expect(system.system, contains('[ ] mine'));
      expect(system.system, isNot(contains('theirs')));
    });

    test('non-request stages pass through', () async {
      store.update('c1', [(text: 'a', state: PlanState.pending)]);
      final middleware = PlanMiddleware(store, 'c1');
      for (final stage in [AgentStage.invocation, AgentStage.compact]) {
        expect((await requestFor(middleware, stage)).system, 'base');
      }
    });
  });

  group(PlanStatusSource, () {
    test('declines empty plans and summarizes non-empty ones', () {
      final source = PlanStatusSource(store);
      expect(source.read('c1'), isNull);
      store.update('c1', [
        (text: 'active work', state: PlanState.inProgress),
        (text: 'later', state: PlanState.pending),
        (text: 'finished', state: PlanState.done),
      ]);
      final summary = source.read('c1') as PlanSummary;
      expect(summary.total, 3);
      expect(summary.done, 1);
      expect(summary.active, 'active work');
      expect(source.read('c2'), isNull);
    });

    test('changes mirrors the store stream', () async {
      final source = PlanStatusSource(store);
      final fired = <int>[];
      final sub = source.changes.listen((_) => fired.add(fired.length + 1));
      store.update('c1', [(text: 'a', state: PlanState.pending)]);
      await Future<void>.delayed(Duration.zero);
      expect(fired, hasLength(1));
      await sub.cancel();
    });
  });

  group('planCommand', () {
    late PluginScope scope;
    late CommandRegistry commands;
    late FakeHostInterface host;
    setUp(() {
      scope = PluginScope('plan-test');
      commands = CommandRegistry(scope);
      host = FakeHostInterface();
      scope.registerContribution(
        pluginId: 'plan',
        id: 'plan',
        contribution: planCommand(store),
      );
    });
    tearDown(() async {
      await scope.dispose();
      await host.dispose();
    });

    Future<void> dispatch(String line) => commands.dispatch(
          line,
          host: host,
          conversationId: 'c1',
        );

    test('empty args show the empty-plan hint', () async {
      await dispatch('/plan');
      // dispatch echoes the line, so the command's answer is the last message.
      expect(host.messages.last, contains('No plan'));
    });

    test('empty args list the current plan', () async {
      store.update('c1', [
        (text: 'first', state: PlanState.done),
        (text: 'second', state: PlanState.inProgress),
      ]);
      await dispatch('/plan');
      expect(host.messages.last, contains('1. [x] first'));
      expect(host.messages.last, contains('2. [~] second'));
    });

    test('add appends a pending item; free text does the same', () async {
      await dispatch('/plan add write tests');
      await dispatch('/plan regex fix');
      final plan = store.read('c1');
      expect(plan.items.map((i) => (i.text, i.state)).toList(), [
        ('write tests', PlanState.pending),
        ('regex fix', PlanState.pending),
      ]);
    });

    test('done/pending toggle by 1-based index', () async {
      await dispatch('/plan add a');
      await dispatch('/plan add b');
      await dispatch('/plan done 1');
      expect(store.read('c1').items[0].state, PlanState.done);
      await dispatch('/plan pending 1');
      expect(store.read('c1').items[0].state, PlanState.pending);
    });

    test('out-of-range toggles fail without mutating', () async {
      await dispatch('/plan done 7');
      expect(host.messages.last, contains('No plan item 7'));
      expect(store.read('c1').isEmpty, isTrue);
    });

    test('clear empties the plan', () async {
      store.update('c1', [(text: 'a', state: PlanState.pending)]);
      await dispatch('/plan clear');
      expect(store.read('c1').isEmpty, isTrue);
      expect(host.messages.last, contains('cleared'));
    });

    test('writes stay in the invoking conversation', () async {
      store.update('c2', [(text: 'other', state: PlanState.pending)]);
      await dispatch('/plan');
      expect(host.messages.last, isNot(contains('other')));
      expect(store.read('c2').items.single.text, 'other');
    });
  });
}
