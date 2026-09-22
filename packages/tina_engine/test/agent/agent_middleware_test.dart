import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

class Middleware extends AgentMiddleware {
  @override
  final String id;
  @override
  String get name => id;
  @override
  final Duration timeout;
  final FutureOr<AgentDecision<AgentInput>> Function(AgentContext, AgentInput)?
      input;
  final FutureOr<AgentDecision<AgentRequest>> Function(
      AgentContext, AgentRequest)? request;
  Middleware(this.id,
      {this.input, this.request, this.timeout = const Duration(seconds: 5)});
  @override
  FutureOr<AgentDecision<AgentInput>> beforeInvocation(
          AgentContext c, AgentInput i) =>
      input?.call(c, i) ?? AgentDecision.next(i);
  @override
  FutureOr<AgentDecision<AgentRequest>> beforeRequest(
          AgentContext c, AgentRequest r) =>
      request?.call(c, r) ?? AgentDecision.next(r);
}

PluginContext plugin(PluginScope scope) => PluginContext(
    plugin:
        PluginDescriptor(id: 'test', factory: FnPluginFactory((_) => Object())),
    scope: scope);

void main() {
  late Directory dir;
  late FakeAgentSink sink;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina_middleware_');
    sink = FakeAgentSink();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Agent build(FakeProvider provider,
          {List<AgentMiddleware> middleware = const [],
          PluginScope? scope,
          List<Tool> tools = const [],
          TokenBudget? budget,
          bool trusted = true}) =>
      Agent(
          provider: provider,
          tools: ToolRegistry(tools),
          policy: PermissionPolicy(allowAllByDefault: true),
          asker: (_) async => PermissionResponse.denyOnce,
          sink: sink,
          system: 'base',
          budget: budget,
          maxSteps: 5,
          promptContext:
              PromptContext(workspaceRoot: dir.path, loadWorkspaceContext: trusted),
          middleware:
              AgentMiddlewarePipeline(scope: scope, middleware: middleware));

  test(
      'invocation hooks run once; request hooks see each step without rewriting history',
      () async {
    final events = <String>[];
    final provider = FakeProvider([
      [
        const MessageComplete(
            content: [ToolUseBlock(id: 't', name: 'fake', input: {})],
            stopReason: 'tool_use')
      ],
      answerEvents('done'),
    ]);
    final agent = build(provider, tools: [
      FakeTool.noOp('fake')
    ], middleware: [
      Middleware('one', input: (context, input) {
        events.add('input');
        expect(context.cwd, dir.path);
        return AgentDecision.next(
            input.copyWith(text: 'transformed', system: 'invocation'));
      }, request: (context, request) {
        events.add('request${context.step}');
        expect(request.system, 'invocation');
        expect(
            () => request.messages
                .add(const Message(role: Role.user, content: [])),
            throwsUnsupportedError);
        return AgentDecision.next(
            request.copyWith(system: '${request.system}\nextra', messages: [
          ...request.messages,
          const Message(role: Role.user, content: [TextBlock('ephemeral')])
        ]));
      }),
      Middleware('two', request: (_, request) {
        expect(request.system, 'invocation\nextra');
        return AgentDecision.next(request);
      }),
    ]);
    final history = <Message>[];
    final persisted = <Message>[];
    agent.onHistoryAppend = (message) async => persisted.add(message);
    await agent.run(history: history, userInput: 'original');
    expect(events, ['input', 'request0', 'request1']);
    expect(provider.calls, hasLength(2));
    expect((history.first.content.single as TextBlock).text, 'transformed');
    expect(
        history
            .expand((m) => m.content)
            .whereType<TextBlock>()
            .map((b) => b.text),
        isNot(contains('ephemeral')));
    expect(persisted, hasLength(4));
  });

  for (final stage in [AgentStage.invocation, AgentStage.request]) {
    test('$stage can reply without a model call and persists the reply',
        () async {
      final provider = FakeProvider([]);
      final agent = build(provider, middleware: [
        Middleware('reply',
            input: stage == AgentStage.invocation
                ? (_, __) => const AgentDecision.reply('handled')
                : null,
            request: stage == AgentStage.request
                ? (_, __) => const AgentDecision.reply('handled')
                : null)
      ]);
      final history = <Message>[];
      await agent.run(history: history, userInput: 'hello');
      expect(provider.calls, isEmpty);
      expect(history, hasLength(2));
      expect((history.last.content.single as TextBlock).text, 'handled');
      expect(sink.texts.join(), 'handled');
    });
  }

  test('cancel an uncooperative middleware; late completion cannot send',
      () async {
    final entered = Completer<AgentContext>();
    final result = Completer<AgentDecision<AgentRequest>>();
    final stop = Completer<void>();
    final provider = FakeProvider([answerEvents('wrong')]);
    final agent = build(provider, middleware: [
      Middleware('wait', request: (context, request) {
        entered.complete(context);
        return result.future;
      })
    ]);
    final pending =
        agent.run(history: [], userInput: 'hello', cancelSignal: stop.future);
    final context = await entered.future;
    stop.complete();
    await pending.timeout(const Duration(seconds: 1));
    await context.cancelSignal;
    result.complete(AgentDecision.next(
        AgentRequest(system: 'late', messages: [], tools: [])));
    await pumpEventQueue();
    expect(provider.calls, isEmpty);
    expect(agent.abortedKind, AbortedKind.cancel);
  });

  test('timeout and failure stop preparation without falling through',
      () async {
    for (final fail in [false, true]) {
      final provider = FakeProvider([]);
      final agent = build(provider, middleware: [
        Middleware('failed', timeout: const Duration(milliseconds: 10),
            request: (_, __) {
          if (fail) throw StateError('private error');
          return Completer<AgentDecision<AgentRequest>>().future;
        })
      ]);
      await agent.run(history: [], userInput: 'hello');
      expect(provider.calls, isEmpty);
      expect(agent.abortedKind, AbortedKind.preparation);
      expect(agent.abortedReason, isNot(contains('private error')));
    }
  });

  for (final cancel in [false, true]) {
    test('hold during preparation waits for resume or cancellation ($cancel)',
        () async {
      final calls = Invocations();
      final call = calls.create(
          component: const ComponentInfo('agent', 'Agent'),
          conversationId: 'conversation');
      final entered = Completer<void>();
      final release = Completer<void>();
      final provider = FakeProvider([answerEvents('done')]);
      final agent = build(provider, middleware: [
        Middleware('held', request: (context, request) async {
          expect(context.agent!.id, 'agent');
          entered.complete();
          await release.future;
          return AgentDecision.next(request);
        })
      ]);
      final pending =
          call.run((_) => agent.run(history: [], userInput: 'hello'));
      final joined = cancel
          ? expectLater(pending, throwsA(isA<InvocationCancelled>()))
          : pending;
      await entered.future;
      final hold = call.hold();
      release.complete();
      await pumpEventQueue();
      expect(provider.calls, isEmpty);
      if (cancel) call.cancel();
      await hold.dispose();
      await joined;
      expect(provider.calls, hasLength(cancel ? 0 : 1));
      await calls.dispose();
    });
  }

  test('transport retries prepare a fresh request without accumulating edits',
      () async {
    final seen = <int>[];
    final provider = FakeProvider([
      [const StreamError('retry', statusCode: 500)],
      answerEvents('done'),
    ]);
    final agent = Agent(
        provider: provider,
        tools: ToolRegistry([]),
        sink: sink,
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'base',
        transportRetryAttempts: 1,
        transportBackoffDelay: (_) async {},
        middleware: AgentMiddlewarePipeline(middleware: [
          Middleware('retry', request: (context, request) {
            seen.add(context.attempt);
            expect(request.system, 'base');
            return AgentDecision.next(request.copyWith(system: 'base extra'));
          })
        ]));
    await agent.run(history: [], userInput: 'hello');
    expect(seen, [0, 1]);
    expect(provider.calls.map((c) => c.system), ['base extra', 'base extra']);
  });

  test('stop finishes admission without calling a provider', () async {
    final provider = FakeProvider([]);
    final history = <Message>[];
    await build(provider, middleware: [
      Middleware('stop', input: (_, __) => const AgentDecision.stop())
    ]).run(history: history, userInput: 'hello');
    expect(provider.calls, isEmpty);
    expect(history, hasLength(1));
  });

  test('budget checks include the final transformed request', () async {
    final provider = FakeProvider([]);
    final agent = build(provider,
        budget: const TokenBudget(perRequestInputLimit: 40),
        middleware: [
          Middleware('large',
              request: (_, request) =>
                  AgentDecision.next(request.copyWith(system: 'x' * 1000)))
        ]);
    await agent.run(history: [], userInput: 'hello');
    expect(provider.calls, isEmpty);
    expect(agent.abortedKind, AbortedKind.budget);
  });

  test('middleware cannot introduce tools and hidden tools do not execute',
      () async {
    final invalid = FakeProvider([]);
    final bad = build(invalid, middleware: [
      Middleware('add',
          request: (_, request) => AgentDecision.next(request.copyWith(tools: [
                const ToolSchema(
                    name: 'added', description: '', inputSchema: {})
              ])))
    ]);
    await bad.run(history: [], userInput: 'hello');
    expect(invalid.calls, isEmpty);
    expect(bad.abortedKind, AbortedKind.preparation);
    var ran = false;
    final provider = FakeProvider([
      [
        const MessageComplete(
            content: [ToolUseBlock(id: 't', name: 'fake', input: {})],
            stopReason: 'tool_use')
      ],
      answerEvents('done'),
    ]);
    final agent = build(provider, tools: [
      FakeTool('fake', (_) async {
        ran = true;
        return const ToolResult('ran');
      })
    ], middleware: [
      Middleware('hide',
          request: (_, request) =>
              AgentDecision.next(request.copyWith(tools: [])))
    ]);
    await agent.run(history: [], userInput: 'hello');
    expect(provider.calls.first.tools, isEmpty);
    expect(ran, isFalse);
  });

  test(
      'live parent and child plugins compose; removal revokes a pending request',
      () async {
    final root = PluginScope('root');
    final child = root.child('child');
    addTearDown(root.dispose);
    final order = <String>[];
    plugin(root).register(Middleware('parent', request: (_, request) {
      order.add('parent');
      return AgentDecision.next(request);
    }));
    final entered = Completer<void>();
    final registration =
        plugin(child).register(Middleware('child', request: (_, __) {
      order.add('child');
      entered.complete();
      return Completer<AgentDecision<AgentRequest>>().future;
    }));
    final provider = FakeProvider([answerEvents('done')]);
    final agent = build(provider, scope: child);
    final pending = agent.run(history: [], userInput: 'hello');
    await entered.future;
    await registration.dispose();
    await pending.timeout(const Duration(seconds: 1));
    expect(provider.calls, isEmpty);
    expect(order, ['parent', 'child']);
    await agent.run(history: [], userInput: 'again');
    expect(provider.calls, hasLength(1));
  });

  test('AGENTS middleware refreshes between tool steps and respects trust',
      () async {
    final instructions = File('${dir.path}/AGENTS.md')
      ..writeAsStringSync('first rules');
    final runtime = PluginRuntime(
        name: 'instructions', plugins: [agentsInstructionsPlugin()]);
    await runtime.activate();
    addTearDown(runtime.dispose);
    final provider = FakeProvider([
      [
        const MessageComplete(
            content: [ToolUseBlock(id: 't', name: 'edit_rules', input: {})],
            stopReason: 'tool_use')
      ],
      answerEvents('done'),
    ]);
    final agent = build(provider, scope: runtime.scope, tools: [
      FakeTool('edit_rules', (_) async {
        instructions.writeAsStringSync('second rules');
        return const ToolResult('updated');
      })
    ]);
    await agent.run(history: [], userInput: 'hello');
    expect(provider.calls.first.system, contains('first rules'));
    expect(provider.calls.last.system, contains('second rules'));
    expect(provider.calls.last.system, isNot(contains('first rules')));
    expect(agent.system, 'base');
    final untrusted = FakeProvider([answerEvents('done')]);
    await build(untrusted, scope: runtime.scope, trusted: false)
        .run(history: [], userInput: 'hello');
    expect(untrusted.calls.single.system, 'base');
  });

  test('compaction passes through request hooks with an explicit stage',
      () async {
    File('${dir.path}/AGENTS.md').writeAsStringSync('DO NOT SUMMARIZE');
    final stages = <AgentStage>[];
    final provider = FakeProvider([answerEvents('summary')]);
    final agent = build(provider, middleware: [
      AgentsInstructions(),
      Middleware('observe', request: (context, request) {
        stages.add(context.stage);
        return AgentDecision.next(request);
      })
    ]);
    final history = [
      const Message(role: Role.user, content: [TextBlock('hi')]),
      const Message(role: Role.assistant, content: [TextBlock('hello')])
    ];
    expect(await agent.compact(history), isTrue);
    expect(stages, [AgentStage.compact]);
    expect(provider.calls.single.system, isNot(contains('DO NOT SUMMARIZE')));
  });

  test(
      'middleware can choose a lazy skill body without a built-in skill injection path',
      () async {
    final scope = PluginScope('skills');
    addTearDown(scope.dispose);
    registerSkill(
        plugin(scope),
        'review',
        Skill(
            info: SkillInfo(name: 'review', description: 'Review'),
            content: 'Review instructions'));
    final skills = Skills(scope);
    plugin(scope)
        .register(Middleware('select', request: (context, request) async {
      final skill = await skills.load('review',
          cwd: context.cwd,
          cancelSignal: context.cancelSignal,
          use: SkillUse.model);
      return AgentDecision.next(
          request.copyWith(system: '${request.system}\n${skill!.content}'));
    }));
    final provider = FakeProvider([answerEvents('done')]);
    await build(provider, scope: scope).run(history: [], userInput: 'review');
    expect(provider.calls.single.system, contains('Review instructions'));
  });
}
