import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_environment.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/memory_session_store.dart';

class ProbeFactory implements AgentDriverFactory {
  late AgentDriverRequest request;
  @override
  AgentDriver create(AgentDriverRequest request) {
    this.request = request;
    return const DefaultAgentDriverFactory().create(request);
  }
}

class Provider extends LlmProvider {
  Provider() : super('test');
  int calls = 0;
  final advertised = <String>[];
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    advertised.addAll(tools.map((t) => t.name));
    if (calls++ == 0) {
      yield const MessageComplete(
        content: [
          ToolUseBlock(
            id: 'bad',
            name: 'bash',
            input: {'command': 'touch file'},
          ),
        ],
        stopReason: 'tool_use',
      );
    } else {
      yield const MessageComplete(
        content: [TextBlock('done')],
        stopReason: 'end_turn',
      );
    }
  }
}

class ProbeTool implements Tool {
  int calls = 0;
  @override
  ToolSchema get schema =>
      const ToolSchema(name: 'bash', description: 'probe', inputSchema: {});
  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    calls++;
    return const ToolResult('executed');
  }
}

void main() {
  for (final delegates in [false, true]) {
    test('composition restricts orchestrator withSubAgents=$delegates', () async {
      final factory = ProbeFactory();
      final provider = Provider();
      final registry = ProviderRegistry(env: const {})
        ..register(
          ProviderDescriptor(
            id: 'test',
            name: 'Test',
            authSources: const [],
            defaultBaseUrl: 'https://example.test',
            builder: (_) => provider,
          ),
        );
      final comp = await buildAppComposition(
        config: RuntimeConfig(provider: 'test', model: 'test'),
        registry: registry,
        store: MemorySessionStore(),
        environment: FakeEnvironment(),
        driverFactory: factory,
      );
      addTearDown(comp.dispose);
      final host = FakeHostInterface();
      addTearDown(host.dispose);
      var approvals = 0;
      final driver = buildAgent(
        pipeline: comp.pipeline,
        scheduler: comp.scheduler,
        conversationId: comp.initialConversationId,
        provider: provider,
        host: host,
        policy: comp.policy,
        config: comp.config,
        withSubAgents: delegates,
        toolAccess: AgentToolAccess.orchestrator,
        asker: (_) async {
          approvals++;
          return PermissionResponse.allowOnce;
        },
      );
      expect(driver.tools.schemas.map((s) => s.name), ['ask_user']);
      for (final name in [
        'bash',
        'exec',
        'read',
        'grep',
        'list_files',
        'delegate',
        'launch_workflow',
        'read_summary',
        'environment_stage',
        'plugin_fs_alias',
      ]) {
        expect(
          combineGuardBlocks(factory.request.executionGuards, name, {}),
          isNotNull,
        );
        expect(driver.tools.executionBlock(name, {}), isNotNull);
      }
      // A per-turn catalog replacement cannot bypass the execution restriction.
      final probe = ProbeTool();
      final history = <Message>[];
      comp.policy.mode = PermissionMode.allowEdits;
      await driver.run(
        history: history,
        userInput: 'inspect',
        turnTools: ToolRegistry([probe]),
      );
      expect(probe.calls, 0);
      expect(approvals, 0);
      final denied = history
          .expand((m) => m.content)
          .whereType<ToolResultBlock>()
          .single;
      expect(denied.isError, isTrue);
      expect(denied.content, contains('This orchestrator cannot access'));
      // Building a sibling in the same scheduler does not inherit this role.
      final sibling = buildAgent(
        pipeline: comp.pipeline,
        scheduler: comp.scheduler,
        conversationId: 'sibling',
        provider: Provider(),
        host: host,
        policy: comp.policy,
        config: comp.config,
        withSubAgents: false,
      );
      expect(sibling.tools['read'], isNotNull);
      expect(
        factory.request.executionGuards.whereType<OrchestratorToolGuard>(),
        isEmpty,
      );
    });
  }
}
