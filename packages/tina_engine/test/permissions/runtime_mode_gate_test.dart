import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/agent_test_fixtures.dart';

void main() {
  for (final standalone in [false, true]) {
    test(
        'live mode reaches ${standalone ? 'workflow nodes' : 'delegated agents'}',
        () async {
      final root = await Directory.systemTemp.createTemp('tina-runtime-mode-');
      addTearDown(() => root.deleteSync(recursive: true));
      final output = File('${root.path}/output');
      final parent = PermissionPolicy();
      final provider = _Provider((step) {
        if (step == 0) {
          parent.mode = PermissionMode.readAll;
          return [
            ToolUseBlock(id: 'write', name: 'write', input: {
              'filePath': output.path,
              'content': 'must not be written',
            })
          ];
        }
        return const [TextBlock('done')];
      });
      final registry = ProviderRegistry(env: const {'TEST_KEY': 'k'});
      registry.register(ProviderDescriptor(
        id: 'test',
        name: 'test',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://test.invalid',
        builder: (_) => provider,
        models: {
          'model': ModelInfo(
              id: 'model',
              name: 'model',
              contextWindow: 100000,
              maxOutput: 1000)
        },
      ));
      final scheduler = testScheduler(registry, pipeline: defaultTestPipeline);
      addTearDown(scheduler.dispose);
      if (standalone) {
        scheduler.basePolicy = parent;
        await scheduler.runStandalone(
            systemPrompt: 'test',
            task: 'work',
            parentReference: 'test/model',
            sink: FakeAgentSink());
      } else {
        await scheduler
            .spawn(
                task: 'work',
                toolProfile: ToolProfile.full,
                parentReference: 'test/model',
                parentPolicy: parent,
                parentSystemPrompt: 'test',
                originConversationId: 'main')
            .result;
      }
      expect(output.existsSync(), isFalse);
      expect(provider.histories, hasLength(2));
      expect(provider.histories.last.join(), contains('disabled in read-all'));
      expect(provider.schemas, everyElement(provider.schemas.first));
    });
  }

  test('a removed notice is reannounced on the next turn', () async {
    final provider = _Provider((_) => const [TextBlock('done')]);
    final agent = Agent(
        provider: provider,
        tools: ToolRegistry([]),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(mode: PermissionMode.readAll),
        asker: (_) async => fail('must not ask'),
        system: 'test');
    final history = <Message>[];
    await agent.run(history: history, userInput: 'first');
    history.clear(); // The same path as cancellation rollback or /clear.
    await agent.run(history: history, userInput: 'next');
    expect(provider.histories.last.join(),
        contains('Runtime permission mode: read-all'));
  });

  test('read-all overrides allows for direct and indirect mutations', () {
    final policy = PermissionPolicy(mode: PermissionMode.readAll);
    for (final name in [
      'bash',
      'write',
      'edit',
      'write_summary',
      'launch_workflow',
      'send',
      'allocate',
      'unknown_plugin',
      'begin_environment_execution',
    ]) {
      policy.remember(name, '*', PermissionDecision.allow);
      expect(policy.check(name, {}), PermissionDecision.deny, reason: name);
    }
    expect(
        policy.check('delegate', {
          'delegations': [
            {'task': 'work', 'tools': 'full'}
          ],
        }),
        PermissionDecision.deny);
    expect(
        policy.executionBlock('delegate', {
          'delegations': [
            {'task': 'inspect'}
          ],
        }),
        isNull);
    policy.mode = PermissionMode.ask;
    expect(policy.check('bash', {}), PermissionDecision.allow);
  });

  test('derived policies share live modes but keep their own approvals', () {
    final parent = PermissionPolicy();
    final child = PermissionPolicy(modeSource: parent);
    final nested = PermissionPolicy(modeSource: child);
    child.remember('bash', '*', PermissionDecision.allow);
    parent.mode = PermissionMode.readAll;
    expect(nested.check('bash', {}), PermissionDecision.deny);
    expect(child.check('bash', {}), PermissionDecision.deny);
    nested.mode = PermissionMode.ask;
    expect(parent.mode, PermissionMode.ask);
    expect(child.check('bash', {}), PermissionDecision.allow);
    expect(parent.check('bash', {}), PermissionDecision.ask);
    expect(nested.check('bash', {}), PermissionDecision.ask);
  });

  test('mode flips preserve schemas, system, and previously sent messages',
      () async {
    final policy = PermissionPolicy(defaults: {
      'bash': PermissionDecision.allow,
      'read': PermissionDecision.allow,
    });
    final bash = _Tool('bash');
    final read = _Tool('read');
    final provider = _Provider((step) {
      if (step == 0) {
        // User switches mode while the model request is in flight.
        policy.mode = PermissionMode.readAll;
        return [_call('bash'), _call('read')];
      }
      if (step == 1) {
        policy.mode = PermissionMode.ask;
        return [_call('bash')];
      }
      return const [TextBlock('done')];
    });
    final history = <Message>[
      const Message(role: Role.user, content: [TextBlock('earlier context')]),
      const Message(
          role: Role.assistant, content: [TextBlock('earlier answer')]),
    ];
    await Agent(
      provider: provider,
      tools: ToolRegistry([bash, read]),
      sink: FakeAgentSink(),
      policy: policy,
      asker: (_) async => fail('runtime rejection must not prompt'),
      system: 'unchanged identity',
    ).run(history: history, userInput: 'inspect');
    expect(bash.calls, 1, reason: 'only runs after leaving read-all');
    expect(read.calls, 1);
    expect(provider.schemas, everyElement(provider.schemas.first));
    expect(provider.systems, everyElement('unchanged identity'));
    for (var i = 1; i < provider.histories.length; i++) {
      final previous = provider.histories[i - 1];
      expect(provider.histories[i].take(previous.length), previous);
    }
    final errors = history
        .expand((m) => m.content)
        .whereType<ToolResultBlock>()
        .where((r) => r.isError)
        .toList();
    expect(errors, hasLength(1));
    expect(errors.single.content, contains('Use read, grep'));
    final notices = history
        .expand((m) => m.content)
        .whereType<TextBlock>()
        .where((b) => b.text.startsWith('Runtime permission mode:'))
        .toList();
    expect(
        notices.map((b) => b.text), [contains('read-all'), contains('ask.')]);
  });

  test(
      'switching to read-all during approval cancels execution and remembering',
      () async {
    final policy = PermissionPolicy();
    final bash = _Tool('bash');
    var asks = 0;
    final history = <Message>[];
    await Agent(
      provider: _Provider(
          (step) => step == 0 ? [_call('bash')] : const [TextBlock('done')]),
      tools: ToolRegistry([bash]),
      sink: FakeAgentSink(),
      policy: policy,
      asker: (_) async {
        asks++;
        policy.mode = PermissionMode.readAll;
        return PermissionResponse.allowAlways;
      },
      system: 'test',
    ).run(history: history, userInput: 'run');
    expect(asks, 1);
    expect(bash.calls, 0);
    expect(policy.sessionRules, isEmpty);
    expect(
        history
            .expand((m) => m.content)
            .whereType<ToolResultBlock>()
            .single
            .content,
        contains('disabled in read-all'));
  });

  test('initial read-all blocks even local control tools before approval',
      () async {
    final transition = _ControlTool('begin_environment_execution');
    final bash = _Tool('bash');
    await Agent(
      provider: _Provider((step) => step == 0
          ? [_call('bash'), _call('begin_environment_execution')]
          : const [TextBlock('done')]),
      tools: ToolRegistry([bash, transition]),
      sink: FakeAgentSink(),
      policy: PermissionPolicy(mode: PermissionMode.readAll, rules: const [
        PermissionRule(
            toolName: 'bash', pattern: '*', decision: PermissionDecision.allow),
      ]),
      asker: (_) async => fail('must not ask'),
      system: 'test',
    ).run(history: [], userInput: 'setup');
    expect(bash.calls, 0);
    expect(transition.calls, 0);
  });
}

ToolUseBlock _call(String name) =>
    ToolUseBlock(id: name, name: name, input: const {});

class _Tool implements Tool {
  final String name;
  int calls = 0;
  _Tool(this.name);
  @override
  ToolSchema get schema => ToolSchema(
      name: name,
      description: 'Use $name',
      inputSchema: const {'type': 'object', 'properties': {}});
  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    calls++;
    return const ToolResult('ok');
  }
}

class _ControlTool extends _Tool implements LocalControlTool {
  _ControlTool(super.name);
}

class _Provider extends LlmProvider {
  final List<ContentBlock> Function(int) respond;
  final schemas = <String>[];
  final systems = <String>[];
  final histories = <List<String>>[];
  _Provider(this.respond) : super('test');
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    final step = schemas.length;
    schemas.add(jsonEncode([
      for (final tool in tools)
        {
          'name': tool.name,
          'description': tool.description,
          'input_schema': tool.inputSchema
        }
    ]));
    systems.add(system);
    histories.add(messages.map((m) => jsonEncode(m.toJson())).toList());
    final content = respond(step);
    yield MessageComplete(
        content: content,
        stopReason:
            content.any((b) => b is ToolUseBlock) ? 'tool_use' : 'end_turn');
  }
}
