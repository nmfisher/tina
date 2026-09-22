import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/src/composition/execution_runtime.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_environment.dart';
import '../helpers/fake_host_interface.dart';

void update(
  LiveQuotas quotas, {
  int turn = 0,
  int session = 0,
  int request = 0,
  int delegated = 0,
  int global = 0,
  int rpm = 0,
}) => quotas.update(
  maxTurnTokens: turn,
  maxSessionTokens: session,
  maxRequestTokens: request,
  maxSubAgentTokens: delegated,
  maxGlobalTokens: global,
  requestsPerMinute: rpm,
);

void main() {
  test(
    'existing budget snapshots read new caps without losing measured or estimated spend',
    () {
      final ledger = SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0);
      final quotas = LiveQuotas(RuntimeConfig(maxTurnTokens: 0), ledger);
      final budget = quotas
          .mainBudget()
          .record(const TokenUsage(inputTokens: 30, outputTokens: 10))
          .recordEstimated(const TokenUsage(inputTokens: 20, outputTokens: 0));
      final child = quotas.delegatedBudget().record(
        const TokenUsage(inputTokens: 80, outputTokens: 0),
      );
      update(quotas, turn: 50, session: 500, request: 100, delegated: 70);
      expect(budget.exceededLimit(), TokenLimitKind.perTurn);
      expect(budget.turnTotal, 40);
      expect(budget.turnEstimated, 20);
      expect(budget.sessionTotal, 40);
      expect(budget.sessionEstimated, 20);
      expect(budget.perRequestInputLimit, 100);
      expect(child.exceededLimit(), TokenLimitKind.perSession);
      update(quotas, turn: 100, delegated: 100);
      expect(budget.exceededLimit(), isNull);
      expect(child.exceededLimit(), isNull);
      update(quotas);
      expect(budget.perTurnLimit, isNull);
      expect(
        budget
            .resetTurn()
            .record(const TokenUsage(inputTokens: 5, outputTokens: 0))
            .perTurnLimit,
        isNull,
      );
      expect(budget.sessionTotal + budget.sessionEstimated, 60);
      expect(quotas.mainBudget().turnTotal, 0);
    },
  );

  test(
    'quota updates are runtime-local and reject invalid input atomically',
    () {
      final a = LiveQuotas(
        RuntimeConfig(),
        SpendLedger(maxGlobalTokens: 100, requestsPerMinute: 0),
      );
      final b = LiveQuotas(
        RuntimeConfig(),
        SpendLedger(maxGlobalTokens: 100, requestsPerMinute: 0),
      );
      update(a, turn: 7);
      expect(b.mainBudget().perTurnLimit, 1000000);
      expect(() => update(a, turn: 20, global: -1), throwsArgumentError);
      expect(a.mainBudget().perTurnLimit, 7);
      expect(a.maxGlobalTokens, 0);
    },
  );

  test(
    'default runtime wires live caps into main, workflow and delegated drivers',
    () async {
      final root = await Directory.systemTemp.createTemp('tina_live_quota_');
      addTearDown(() => root.delete(recursive: true));
      final factory = _Factory();
      final registry = ProviderRegistry(env: const {})
        ..register(
          ProviderDescriptor(
            id: 'test',
            name: 'Test',
            authSources: const [],
            defaultBaseUrl: 'https://test.invalid',
            builder: (c) => _Provider(c.model),
          ),
        );
      final config = RuntimeConfig(provider: 'test', model: 'm');
      final runtime = await buildExecutionRuntime(
        config: config,
        registry: registry,
        environment: FakeEnvironment(),
        workspaceRoot: root.path,
        driverFactory: factory,
      );
      addTearDown(runtime.dispose);
      final quotas = runtime.pluginScope.lookup(liveQuotasServiceKey)!;
      final provider = runtime.buildStartupProvider();
      addTearDown(provider.close);
      buildAgent(
        pipeline: runtime.pipeline,
        scheduler: runtime.scheduler,
        conversationId: 'main',
        provider: provider,
        host: FakeHostInterface(),
        policy: PermissionPolicy(),
        config: config,
        withSubAgents: false,
      );
      await runtime.scheduler.runStandalone(
        systemPrompt: 'sys',
        task: 'work',
        parentReference: 'test/m',
        sink: FakeAgentSink(),
      );
      final job = runtime.scheduler.spawn(
        task: 'work',
        toolProfile: ToolProfile.readOnly,
        parentSystemPrompt: 'sys',
        parentReference: 'test/m',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'main',
      );
      await job.result;
      expect(factory.budgets, hasLength(3));
      update(
        quotas,
        turn: 41,
        session: 42,
        request: 43,
        delegated: 44,
        global: 500,
        rpm: 60,
      );
      expect(factory.budgets.first.perTurnLimit, 41);
      expect(factory.budgets.first.perSessionLimit, 42);
      expect(factory.budgets.first.perRequestInputLimit, 43);
      expect(factory.budgets.skip(1).map((b) => b.perSessionLimit), [44, 44]);
      expect(runtime.spendLedger.cap, 500);
      expect(runtime.spendLedger.rpm, 60);
      await runtime.scheduler.runStandalone(
        systemPrompt: 'sys',
        task: 'next',
        parentReference: 'test/m',
        sink: FakeAgentSink(),
      );
      expect(factory.budgets.last.perSessionLimit, 44);
    },
  );

  test(
    'an in-flight turn sees a raised cap when its response completes',
    () async {
      final quotas = LiveQuotas(
        RuntimeConfig(maxTurnTokens: 10),
        SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0),
      );
      final started = Completer<void>();
      final release = Completer<void>();
      final provider = _Provider(
        'm',
        onSend: () async {
          started.complete();
          await release.future;
        },
      );
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([]),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        system: 'sys',
        budget: quotas.mainBudget(),
      );
      final pending = agent.run(history: [], userInput: 'work');
      await started.future;
      update(quotas, turn: 100);
      release.complete();
      await pending;
      expect(agent.abortedReason, isNull);
      expect(agent.budget!.turnTotal, 20);
      expect(agent.budget!.perTurnLimit, 100);
    },
  );
}

class _Factory implements AgentDriverFactory {
  final budgets = <TokenBudget>[];
  @override
  AgentDriver create(AgentDriverRequest request) {
    budgets.add(request.budget!);
    return const DefaultAgentDriverFactory().create(request);
  }
}

class _Provider extends LlmProvider {
  final Future<void> Function()? onSend;
  _Provider(super.model, {this.onSend});
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    await onSend?.call();
    yield const MessageComplete(
      content: [TextBlock('done')],
      stopReason: 'end_turn',
      usage: TokenUsage(inputTokens: 15, outputTokens: 5),
    );
  }
}
