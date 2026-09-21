import 'dart:async';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'package:tina_app/src/classification/classification_agent_runner.dart';
import 'package:tina_engine/tina_engine.dart';

class ScriptedProvider extends LlmProvider {
  final List<List<StreamEvent>> responses;
  ScriptedProvider(this.responses) : super('test');
  var calls = 0;
  var closed = false;
  final catalogs = <List<String>>[];
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    catalogs.add(tools.map((t) => t.name).toList());
    return calls < responses.length
        ? Stream.fromIterable(responses[calls++])
        : StreamController<StreamEvent>().stream;
  }

  @override
  void close() {
    closed = true;
  }
}

class Factory implements AgentDriverFactory {
  AgentDriverRequest? request;
  @override
  AgentDriver create(AgentDriverRequest request) {
    this.request = request;
    return const DefaultAgentDriverFactory().create(request);
  }
}

List<StreamEvent> tool(String name, Map<String, dynamic> input) => [
  MessageComplete(
    content: [ToolUseBlock(id: name, name: name, input: input)],
    stopReason: 'tool_use',
  ),
];
const done = [
  MessageComplete(content: [TextBlock('Done')], stopReason: 'end_turn'),
];
final categoryContract = DataContract<String>(
  id: 'test.category',
  schema: {'type': 'string'},
  encode: (v) => v,
  decode: (v) => v as String,
);
Map<String, dynamic> result({String evidence = 'input:1'}) => {
  'outcome': 'classified',
  'value': 'positive',
  'evidence': [evidence],
  'explanation': 'supported by the input',
};

void main() {
  late JudgmentCancellation stop;
  late ClassificationRequest<TextEvidence, String> request;
  setUp(() {
    stop = JudgmentCancellation();
    request = ClassificationRequest(
      ClassifierDefinition(
        id: 'sentiment',
        agentType: 'sentiment_agent',
        instructions: 'Classify sentiment.',
        input: textEvidenceContract,
        output: categoryContract,
      ),
      ClassificationInput([
        SourceUnit(
          'input:1',
          TextEvidence('customer feedback', 'Useful product.'),
        ),
      ], InputCoverage()),
    );
  });
  EngineClassificationExecutor runner(
    ScriptedProvider provider, {
    Factory? factory,
    PermissionPolicy? policy,
  }) => EngineClassificationExecutor(
    createProvider: (_) => provider,
    configuration: 'test',
    driverFactory: factory ?? Factory(),
    policy: policy ?? PermissionPolicy(),
  );
  Future<ClassificationResult<String>> run(
    EngineClassificationExecutor executor, {
    int limit = 12000,
  }) => executor.execute(
    request,
    stop,
    maxInputTokens: limit,
    maxOutputTokens: 4096,
  );

  test(
    'generic agent accepts prepared text and a typed output with no source tools',
    () async {
      final provider = ScriptedProvider([
        tool('submit_classification', result()),
      ]);
      final factory = Factory();
      final output = await run(runner(provider, factory: factory));
      expect(output.value, 'positive');
      expect(provider.closed, isTrue);
      expect(provider.calls, 1);
      expect(provider.catalogs.single, ['submit_classification']);
      expect(factory.request!.system, contains('sentiment_agent'));
    },
  );

  test('invented citations and unstructured prose fail with cleanup', () async {
    final provider = ScriptedProvider([
      tool('submit_classification', result(evidence: 'fake')),
      done,
    ]);
    await expectLater(run(runner(provider)), throwsStateError);
    expect(provider.closed, isTrue);
  });

  test(
    'cancellation closes a provider whose stream has not finished',
    () async {
      final provider = ScriptedProvider([]);
      final pending = run(runner(provider));
      await Future<void>.delayed(Duration.zero);
      stop.cancel();
      await expectLater(
        pending.timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
      expect(provider.closed, isTrue);
    },
  );

  test('pre-cancelled requests create no provider', () async {
    stop.cancel();
    var created = 0;
    final executor = EngineClassificationExecutor(
      createProvider: (_) {
        created++;
        return ScriptedProvider([]);
      },
      configuration: 'test',
      policy: PermissionPolicy(),
    );
    await expectLater(run(executor), throwsStateError);
    expect(created, 0);
  });

  test('explicit denies still block result submission', () async {
    final provider = ScriptedProvider([
      tool('submit_classification', result()),
      done,
    ]);
    final policy = PermissionPolicy(
      rules: const [
        PermissionRule(
          toolName: 'submit_classification',
          pattern: '*',
          decision: PermissionDecision.deny,
        ),
      ],
    );
    await expectLater(run(runner(provider, policy: policy)), throwsStateError);
    expect(provider.closed, isTrue);
  });

  test(
    'complete request budget rejects before provider construction',
    () async {
      var created = 0;
      final executor = EngineClassificationExecutor(
        createProvider: (_) {
          created++;
          return ScriptedProvider([]);
        },
        configuration: 'test',
        policy: PermissionPolicy(),
      );
      expect(executor.estimate(request), greaterThan('Useful product.'.length));
      await expectLater(
        run(executor, limit: executor.estimate(request) - 1),
        throwsA(isA<InputTooLargeException>()),
      );
      expect(created, 0);
    },
  );
}
