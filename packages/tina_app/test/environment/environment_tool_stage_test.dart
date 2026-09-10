import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';

const plan = {
  'findings': 'Inspected pubspec.yaml and the test directory.',
  'setup': 'dart pub get',
  'build': 'dart compile exe bin/main.dart',
  'test': 'dart test',
};
ToolUseBlock call(String name, [Map<String, dynamic> input = const {}]) =>
    ToolUseBlock(id: name, name: name, input: input);

void main() {
  late _Tool read;
  late _Tool bash;
  late _Tool write;
  late ToolRegistry base;
  setUp(() {
    read = _Tool('read');
    bash = _Tool('bash');
    write = _Tool('write');
    base = ToolRegistry([
      read,
      bash,
      write,
      _Tool('launch_workflow'),
      _Tool('send'),
      _Tool('unrecognized_plugin'),
      EnvironmentToolStage.transitionTool,
    ]);
  });

  test('inspection gates execution without changing advertised schemas', () {
    final stage = EnvironmentToolStage(base);
    expect(schemaJson(stage.schemas), schemaJson(base.schemas));
    for (final name in [
      'bash',
      'write',
      'launch_workflow',
      'send',
      'unrecognized_plugin',
    ]) {
      expect(stage[name], isNotNull);
      expect(stage.executionBlock(name, {}), isNotNull);
    }
    expect(base['bash'], same(bash));
  });

  test('environment delegates expose only the read-only profile', () async {
    final scheduler = SubAgentScheduler(
      registry: ProviderRegistry(env: const {}),
      pipeline: AgentPipeline(),
      maxTokens: 1024,
      streamIdleTimeout: const Duration(seconds: 10),
      requestTimeout: const Duration(seconds: 10),
    );
    final delegate = DelegateTool(
      AgentToolContext(
        scheduler: scheduler,
        pipeline: scheduler.pipeline,
        parentReference: 'test/test',
        parentPolicy: PermissionPolicy(),
        originConversationId: 'main',
        depth: 0,
        parentSystemPrompt: 'test',
      ),
    );
    final stage = EnvironmentToolStage(ToolRegistry([delegate]));
    final result = await stage['delegate']!.execute({
      'delegations': [
        {'task': 'inspect', 'tools': 'full'},
      ],
    });
    expect(result.isError, isTrue);
    expect(scheduler.jobs, isEmpty);
    expect(
      stage.executionBlock('begin_environment_execution', plan),
      isNotNull,
    );
    await scheduler.dispose();
  });

  test(
    'transition requires successful inspection and a concrete plan',
    () async {
      final stage = EnvironmentToolStage(base);
      expect(
        stage.executionBlock('begin_environment_execution', plan),
        isNotNull,
      );
      read.error = true;
      await stage['read']!.execute({});
      expect(
        stage.executionBlock('begin_environment_execution', plan),
        isNotNull,
      );
      read.error = false;
      await stage['read']!.execute({});
      final transition = stage['begin_environment_execution']!;
      expect(
        (await transition.execute({'findings': 'guessed'})).isError,
        isTrue,
      );
      expect(stage.executionBlock('bash', {}), isNotNull);
      expect((await transition.execute(plan)).isError, isFalse);
      expect(stage['bash'], same(bash));
      expect(
        stage.executionBlock('begin_environment_execution', plan),
        isNotNull,
      );
      expect(bash.calls, 0, reason: 'transition does not execute the plan');
    },
  );

  test(
    'pre-approved calls are gated by step while the catalog stays identical',
    () async {
      final provider = _Provider([
        [call('bash'), call('read'), call('begin_environment_execution', plan)],
        [call('begin_environment_execution', plan), call('bash')],
        [call('bash'), call('write')],
      ]);
      var asks = 0;
      final agent = Agent(
        provider: provider,
        tools: base,
        sink: FakeAgentSink(),
        policy: PermissionPolicy(
          defaults: {
            'read': PermissionDecision.allow,
            'bash': PermissionDecision.allow,
            'write': PermissionDecision.allow,
          },
        ),
        asker: (_) async {
          asks++;
          return PermissionResponse.denyOnce;
        },
        system: 'test',
      );
      final history = <Message>[];
      await agent.run(
        history: history,
        userInput: 'setup',
        turnTools: EnvironmentToolStage(base),
      );
      expect(provider.schemas, everyElement(schemaJson(base.schemas)));
      expect(bash.calls, 1);
      expect(write.calls, 1);
      expect(asks, 0, reason: 'phase transition requires no approval');
      expect(
        history
            .expand((m) => m.content)
            .whereType<ToolResultBlock>()
            .where((r) => r.isError),
        hasLength(3),
      );
    },
  );

  test('execution still applies ordinary command approval', () async {
    final provider = _Provider([
      [call('read')],
      [call('begin_environment_execution', plan)],
      [call('bash')],
    ]);
    final asked = <String>[];
    await Agent(
      provider: provider,
      tools: base,
      sink: FakeAgentSink(),
      policy: PermissionPolicy(),
      asker: (p) async {
        asked.add(p.toolName);
        return PermissionResponse.denyOnce;
      },
      system: 'test',
    ).run(
      history: [],
      userInput: 'setup',
      turnTools: EnvironmentToolStage(base),
    );
    expect(asked, ['bash']);
    expect(bash.calls, 0);
  });

  test(
    'one turn cannot change an unrelated registry or the next turn',
    () async {
      final stage = EnvironmentToolStage(base);
      final other = EnvironmentToolStage(base);
      await stage['read']!.execute({});
      await stage['begin_environment_execution']!.execute(plan);
      expect(other.executionBlock('bash', {}), isNotNull);
      final provider = _Provider([
        [call('bash')],
      ]);
      await Agent(
        provider: provider,
        tools: base,
        sink: FakeAgentSink(),
        policy: PermissionPolicy(defaults: {'bash': PermissionDecision.allow}),
        asker: (_) async => fail('already allowed'),
        system: 'test',
      ).run(history: [], userInput: 'ordinary task');
      expect(bash.calls, 1);
    },
  );

  test('safe-mode capabilities cannot be reintroduced by transition', () async {
    final stage = EnvironmentToolStage(ToolRegistry([read]));
    await stage['read']!.execute({});
    await stage['begin_environment_execution']!.execute(plan);
    expect(stage['bash'], isNull);
    expect(stage['write'], isNull);
  });

  test(
    'cancellation after inspection leaves the base registry untouched',
    () async {
      final cancel = Completer<void>();
      read.after = cancel.complete;
      final agent = Agent(
        provider: _Provider([
          [call('read')],
        ]),
        tools: base,
        sink: FakeAgentSink(),
        policy: PermissionPolicy(),
        asker: (_) async => fail('no approval'),
        system: 'test',
      );
      await agent.run(
        history: [],
        userInput: 'setup',
        cancelSignal: cancel.future,
        turnTools: EnvironmentToolStage(base),
      );
      expect(base['bash'], same(bash));
      expect(
        EnvironmentToolStage(
          base,
        ).executionBlock('begin_environment_execution', plan),
        isNotNull,
      );
    },
  );
}

class _Tool implements Tool {
  final String name;
  int calls = 0;
  bool error = false;
  void Function()? after;
  _Tool(this.name);
  @override
  ToolSchema get schema => ToolSchema(
    name: name,
    description: name,
    inputSchema: const {'type': 'object'},
  );
  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    calls++;
    after?.call();
    return ToolResult('inspected', isError: error);
  }
}

class _Provider extends LlmProvider {
  final List<List<ContentBlock>> steps;
  final schemas = <String>[];
  int index = 0;
  _Provider(this.steps) : super('test');
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    schemas.add(schemaJson(tools));
    yield MessageComplete(
      content: index < steps.length
          ? steps[index++]
          : const [TextBlock('done')],
      stopReason: index <= steps.length ? 'tool_use' : 'end_turn',
    );
  }
}

String schemaJson(List<ToolSchema> tools) => jsonEncode([
  for (final tool in tools)
    {
      'name': tool.name,
      'description': tool.description,
      'input_schema': tool.inputSchema,
    },
]);
