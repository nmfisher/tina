import 'package:tina_engine/tina_engine.dart';

import 'fake_provider.dart';

/// A single assistant turn that answers [text].
List<StreamEvent> answerEvents(String text) => [
      TextDelta(text),
      MessageComplete(content: [TextBlock(text)], stopReason: 'end_turn'),
    ];

/// A [ProviderRegistry] where each key is a provider id and each value is the
/// one response that provider will return. Models are named `$id-model`.
///
/// This deduplicates the copy-pasted `_scriptedRegistry` helper across
/// `sub_agent_scheduler_test.dart`, `channel_tools_test.dart`, and
/// `delegate_task_test.dart`.
ProviderRegistry scriptedRegistry(
  Map<String, List<StreamEvent>> scripts, {
  Map<String, String> env = const {'TEST_KEY': 'k'},
}) {
  final r = ProviderRegistry(env: env);
  for (final entry in scripts.entries) {
    final id = entry.key;
    r.register(ProviderDescriptor(
      id: id,
      name: id,
      authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
      defaultBaseUrl: 'https://$id.test',
      builder: (c) => FakeProvider([entry.value], model: c.model),
      models: {
        '$id-model': ModelInfo(
            id: '$id-model', name: 'm', contextWindow: 1, maxOutput: 1)
      },
    ));
  }
  return r;
}

/// A minimal pipeline (entry identity only — there is no sub-agent catalog).
final AgentPipeline defaultTestPipeline = AgentPipeline(mainIdentity: 'main-id');

/// The parent identity threaded into a test [AgentToolContext], so tests can
/// assert a sub-agent inherited it.
const String testParentSystemPrompt = 'PARENT-IDENTITY';

/// A standard [AgentToolContext] for tool tests.
AgentToolContext testContext(
  SubAgentScheduler scheduler, {
  required AgentPipeline pipeline,
  String parentReference = 'a/a-model',
  PermissionPolicy? parentPolicy,
  String originConversationId = 'c1',
  int depth = 0,
  String parentSystemPrompt = testParentSystemPrompt,
}) =>
    AgentToolContext(
      scheduler: scheduler,
      pipeline: pipeline,
      parentReference: parentReference,
      parentPolicy: parentPolicy ?? PermissionPolicy(),
      originConversationId: originConversationId,
      depth: depth,
      parentSystemPrompt: parentSystemPrompt,
    );

/// A [SubAgentScheduler] pre-filled with the standard test defaults.
///
/// This removes the repeated `maxTokens: 8192` /
/// `streamIdleTimeout: const Duration(seconds: 60)` argument blocks across the
/// scheduler tests.
SubAgentScheduler testScheduler(
  ProviderRegistry registry, {
  required AgentPipeline pipeline,
  int maxTokens = 8192,
  Duration streamIdleTimeout = const Duration(seconds: 60),
  AgentQuota? quota,
  int? maxConcurrent,
  int? maxDepth,
  int subAgentBudgetLimit = 0,
  int defaultMaxSteps = 25,
  PauseGate? pauseGate,
  bool safeMode = false,
}) =>
    SubAgentScheduler(
      registry: registry,
      pipeline: pipeline,
      maxTokens: maxTokens,
      streamIdleTimeout: streamIdleTimeout,
      requestTimeout: const Duration(seconds: 30),
      quota: quota,
      maxConcurrent: maxConcurrent ?? 6,
      maxDepth: maxDepth ?? 3,
      subAgentBudgetLimit: subAgentBudgetLimit,
      defaultMaxSteps: defaultMaxSteps,
      pauseGate: pauseGate,
      safeMode: safeMode,
    );
