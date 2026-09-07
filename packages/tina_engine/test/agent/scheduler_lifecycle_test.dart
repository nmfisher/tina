import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_agent_sink.dart';

class _Provider extends LlmProvider {
  final bool gated;
  final entered = Completer<void>();
  int closes = 0;
  bool cancelled = false;
  _Provider({this.gated = false}) : super('model');
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      List<ToolSchema>? tools}) {
    if (!gated)
      return Stream.value(const MessageComplete(
          content: [TextBlock('done')], stopReason: 'end_turn'));
    return StreamController<StreamEvent>(
      onListen: () => entered.complete(),
      onCancel: () {
        cancelled = true;
      },
    ).stream;
  }

  @override
  void close() {
    closes++;
  }
}

void main() {
  for (final standalone in [false, true]) {
    test(
        'shutdown awaits cancellation and closes provider: standalone=$standalone',
        () async {
      final provider = _Provider(gated: true);
      final registry = ProviderRegistry(env: const {})
        ..register(ProviderDescriptor(
            id: 'test',
            name: 'Test',
            authSources: const [],
            defaultBaseUrl: 'https://example.test',
            builder: (_) => provider));
      final scheduler = SubAgentScheduler(
          registry: registry,
          pipeline: AgentPipeline(),
          maxTokens: 1024,
          streamIdleTimeout: const Duration(seconds: 5),
          requestTimeout: const Duration(seconds: 5));
      final Future<dynamic> result;
      if (standalone) {
        result = scheduler.runStandalone(
            systemPrompt: 'test',
            task: 'wait',
            parentReference: 'test/model',
            sink: FakeAgentSink());
      } else {
        result = scheduler
            .spawn(
                toolProfile: ToolProfile.readOnly,
                task: 'wait',
                parentSystemPrompt: 'test',
                parentReference: 'test/model',
                parentPolicy: PermissionPolicy(),
                originConversationId: 'main')
            .result;
      }
      await provider.entered.future;
      final closing = scheduler.dispose();
      expect(scheduler.dispose(), same(closing));
      await closing;
      await result;
      expect(provider.cancelled, isTrue);
      expect(provider.closes, 1);
      final rejected = await scheduler.runStandalone(
          systemPrompt: 'test',
          task: 'late',
          parentReference: 'test/model',
          sink: FakeAgentSink());
      expect(rejected.isError, isTrue);
      expect(provider.closes, 1);
    });
  }

  test('standalone setup failure closes its acquired provider', () async {
    final provider = _Provider();
    final registry = ProviderRegistry(env: const {})
      ..register(ProviderDescriptor(
          id: 'test',
          name: 'Test',
          authSources: const [],
          defaultBaseUrl: 'https://example.test',
          builder: (_) => provider));
    final scheduler = SubAgentScheduler(
        registry: registry,
        pipeline: AgentPipeline(),
        maxTokens: 1024,
        streamIdleTimeout: const Duration(seconds: 5),
        requestTimeout: const Duration(seconds: 5))
      ..delegateToolBuilder = (_) => throw StateError('tool setup');
    await expectLater(
        scheduler.runStandalone(
            systemPrompt: 'test',
            task: 'test',
            parentReference: 'test/model',
            sink: FakeAgentSink()),
        throwsStateError);
    expect(provider.closes, 1);
    await scheduler.dispose();
    expect(provider.closes, 1);
  });
}
