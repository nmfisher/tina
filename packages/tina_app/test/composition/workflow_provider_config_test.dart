import 'dart:convert';
import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tina_app/src/workflows/tina_codergen_backend.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';

/// Records actual adapter requests. No network or real credentials are used.
class _Client extends http.BaseClient {
  final int status;
  final bool delegate;
  final requests = <({Uri url, String? auth, Map<String, dynamic> body})>[];

  _Client({this.status = 200, this.delegate = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body =
        jsonDecode(await request.finalize().bytesToString())
            as Map<String, dynamic>;
    requests.add((
      url: request.url,
      auth: request.headers['authorization'],
      body: body,
    ));
    if (status != 200) {
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            '{"error":{"message":"Authentication parameter not received in Header"}}',
          ),
        ),
        status,
      );
    }
    final nestedCall =
        delegate &&
        body['model'] == 'review' &&
        requests.where((r) => r.body['model'] == 'review').length == 1;
    final delta = nestedCall
        ? {
            'tool_calls': [
              {
                'index': 0,
                'id': 'delegate-1',
                'type': 'function',
                'function': {
                  'name': 'delegate',
                  'arguments': jsonEncode({
                    'delegations': [
                      {
                        'task': 'Inspect the plan',
                        'llm_provider': 'test',
                        'llm_model': 'nested',
                        'tools': 'read-only',
                      },
                    ],
                  }),
                },
              },
            ],
          }
        : {'content': 'VERDICT: approve'};
    final chunk = jsonEncode({
      'choices': [
        {'delta': delta, 'finish_reason': nestedCall ? 'tool_calls' : 'stop'},
      ],
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode('data: $chunk\n\ndata: [DONE]\n\n')),
      200,
    );
  }

  @override
  void close() {}
}

Future<
  ({
    TinaCodergenBackend backend,
    SubAgentScheduler scheduler,
    LlmProvider parent,
    List<ProviderInstance> instances,
  })
>
_setup(_Client client) async {
  final root = await Directory.systemTemp.createTemp('tina_workflow_config_');
  addTearDown(() => root.delete(recursive: true));
  final config = RuntimeConfig(
    provider: 'test',
    model: 'main',
    apiKey: 'fixture-runtime-key',
    baseUrl: 'https://override.test/v1',
    maxTokens: 1234,
    streamIdleTimeout: const Duration(seconds: 17),
    requestTimeout: const Duration(seconds: 19),
  );
  final instances = <ProviderInstance>[];
  final registry = ProviderRegistry(
    env: const {'OTHER_KEY': 'fixture-other-key'},
  );
  for (final id in ['test', 'other']) {
    registry.register(
      ProviderDescriptor(
        id: id,
        name: id,
        authSources: [
          AuthSource(
            id == 'test' ? 'TEST_KEY' : 'OTHER_KEY',
            AuthScheme.bearerToken,
          ),
        ],
        defaultBaseUrl: 'https://$id.test/v1',
        builder: (c) {
          instances.add(c);
          return OpenAiCompatibleAdapter(
            apiKey: c.apiKey,
            model: c.model,
            baseUrl: c.baseUrl,
            maxTokens: c.maxTokens,
            streamIdleTimeout: c.streamIdleTimeout,
            requestTimeout: c.requestTimeout,
            label: id,
            client: client,
          );
        },
      ),
    );
  }
  final runtime = PluginRuntime(
    name: 'workflow-config',
    plugins: [
      spendLedgerPlugin(config),
      providerFactoryPlugin(config, registry, PauseGate()),
    ],
  );
  await runtime.activate();
  addTearDown(runtime.dispose);
  final factory = runtime.scope.lookup(providerFactoryServiceKey)!;
  final parent = buildResolved(
    factory,
    config,
    'test/main',
    apiKeyOverride: config.apiKey,
    baseUrlOverride: config.baseUrl,
  );
  addTearDown(parent.close);
  final scheduler = createScheduler(
    config: config,
    registry: registry,
    providers: factory,
    pipeline: AgentPipeline(
      promptContext: PromptContext(
        projectRoot: root.path,
        loadProjectContext: false,
      ),
    ),
  );
  addTearDown(scheduler.dispose);
  return (
    backend: TinaCodergenBackend(
      scheduler: scheduler,
      sink: FakeAgentSink(),
      defaultModelReference: 'test/main',
    ),
    scheduler: scheduler,
    parent: parent,
    instances: instances,
  );
}

void main() {
  test(
    'workflow and nested delegate inherit runtime credentials and settings',
    () async {
      final client = _Client(delegate: true);
      final fixture = await _setup(client);
      await fixture.parent
          .send(system: 'test', messages: [], tools: [])
          .drain<void>();
      final result = await fixture.backend.run(
        node: PipelineNode(
          id: 'review',
          attrs: {'llm_model': 'review', 'llm_provider': 'test'},
        ),
        prompt: 'Review the plan',
        preamble: '',
        context: Context(),
      );
      expect(result.outcome?.status, StageStatus.success);
      expect(result.outcome?.preferredLabel, 'approve');
      expect(client.requests.map((r) => r.body['model']), [
        'main',
        'review',
        'nested',
        'review',
      ]);
      for (final request in client.requests) {
        expect(request.auth, 'Bearer fixture-runtime-key');
        expect(
          request.url.toString(),
          'https://override.test/v1/chat/completions',
        );
        expect(request.body['max_tokens'], 1234);
      }
      for (final instance in fixture.instances) {
        expect(instance.streamIdleTimeout, const Duration(seconds: 17));
        expect(instance.requestTimeout, const Duration(seconds: 19));
      }
    },
  );

  test(
    'workflow without model attributes inherits the conversation model',
    () async {
      final client = _Client();
      final fixture = await _setup(client);
      final result = await fixture.backend.run(
        node: PipelineNode(id: 'review'),
        prompt: 'Review',
        preamble: '',
        context: Context(),
      );
      expect(result.outcome?.status, StageStatus.success);
      expect(client.requests.single.body['model'], 'main');
      expect(client.requests.single.auth, 'Bearer fixture-runtime-key');
      expect(client.requests.single.url.host, 'override.test');
    },
  );

  test(
    'explicit different provider resolves its own key and endpoint',
    () async {
      final client = _Client();
      final fixture = await _setup(client);
      final result = await fixture.backend.run(
        node: PipelineNode(
          id: 'review',
          attrs: {'llm_provider': 'other', 'llm_model': 'alternate'},
        ),
        prompt: 'Review',
        preamble: '',
        context: Context(),
      );
      expect(result.outcome?.status, StageStatus.success);
      expect(client.requests.single.body['model'], 'alternate');
      expect(client.requests.single.auth, 'Bearer fixture-other-key');
      expect(client.requests.single.url.host, 'other.test');
    },
  );

  for (final status in [401, 403]) {
    test('$status fails the workflow once with its original cause', () async {
      final client = _Client(status: status);
      final fixture = await _setup(client);
      final handlers = NodeHandlerRegistry()
        ..register('start', StartHandler())
        ..register('exit', ExitHandler())
        ..register('codergen', CodergenHandler(fixture.backend));
      final engine = PipelineEngine(
        graph: parseDot('''digraph Review {
        start [shape=Mdiamond]
        review [shape=box, max_retries=3]
        clarify [shape=box]
        execute [shape=box]
        exit [shape=Msquare]
        start -> review
        review -> clarify [label="clarify"]
        review -> review [label="revise"]
        review -> execute [label="approve"]
        clarify -> review
        execute -> exit
      }'''),
        registry: handlers,
        runStore: MemoryRunStore(),
        runId: 'r1',
        workflowName: 'Review',
        backoffFor: (_) => Duration.zero,
      );
      final result = await engine.run();
      expect(result.status, StageStatus.fail);
      expect(result.failureReason, contains('$status'));
      expect(
        result.failureReason,
        contains('Authentication parameter not received in Header'),
      );
      expect(result.failureReason, isNot(contains('ran out of steps')));
      expect(client.requests, hasLength(1));
    });
  }

  test('delegated agent preserves the original authentication error', () async {
    final fixture = await _setup(_Client(status: 401));
    final job = fixture.scheduler.spawn(
      task: 'Inspect',
      toolProfile: ToolProfile.readOnly,
      parentSystemPrompt: 'test',
      parentReference: 'test/main',
      parentPolicy: PermissionPolicy(),
      originConversationId: 'parent',
    );
    final result = await job.result;
    expect(result.isError, isTrue);
    expect(result.content, contains('401'));
    expect(
      result.content,
      contains('Authentication parameter not received in Header'),
    );
  });

  test('invalid provider configuration is terminal before sending', () async {
    final client = _Client();
    final fixture = await _setup(client);
    final result = await fixture.backend.run(
      node: PipelineNode(
        id: 'review',
        attrs: {'llm_provider': 'missing', 'llm_model': 'review'},
      ),
      prompt: 'Review',
      preamble: '',
      context: Context(),
    );
    expect(result.outcome?.status, StageStatus.fail);
    expect(result.outcome?.failureReason, contains('failed to build provider'));
    expect(client.requests, isEmpty);
  });
}
