import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/agent_test_fixtures.dart';
import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';

const _empty = MessageComplete(content: [], stopReason: 'stop');
const _ok = MessageComplete(
  content: [TextBlock('recovered')],
  stopReason: 'stop',
);

Agent _agent(LlmProvider provider, FakeAgentSink sink) => Agent(
      provider: provider,
      tools: ToolRegistry([]),
      sink: sink,
      system: 'sys',
      policy: PermissionPolicy(),
      asker: (_) async => PermissionResponse.denyOnce,
      emptyCompletionBackoffDelay: (_) async {},
    );

/// Exercises the real adapter with a reasoning-only SSE response whose finish
/// reason previously failed to reach the agent.
class _ReasoningClient extends http.BaseClient {
  final bodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    bodies.add((request as http.Request).body);
    final event = {
      'choices': [
        {
          'delta': {'reasoning_content': 'reasoning without a final answer'},
          'finish_reason': 'length',
        },
      ],
      'usage': {'prompt_tokens': 10, 'completion_tokens': 8192},
    };
    return http.StreamedResponse(
      Stream.value(
          utf8.encode('data: ${jsonEncode(event)}\n\ndata: [DONE]\n\n')),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

void main() {
  test('agent recovers after an entire pool returns empty responses', () async {
    final a = FakeProvider([
      [_empty],
      [_ok]
    ]);
    final b = FakeProvider([
      [_empty]
    ]);
    final provider = RetryingProvider(
      PooledProvider([a, b], cooldown: Duration.zero),
      maxRetries: 1,
    );
    final sink = FakeAgentSink();
    final agent = _agent(provider, sink);
    final history = <Message>[];

    await agent.run(history: history, userInput: 'hi');

    expect(agent.abortedReason, isNull);
    expect(a.calls, hasLength(2));
    expect(b.calls, hasLength(1));
    expect(sink.notices.map((n) => n.message), contains(contains('retry 1/1')));
    final assistant = history.where((m) => m.role == Role.assistant).single;
    expect((assistant.content.single as TextBlock).text, 'recovered');
  });

  test('exhausted pool retries remain bounded', () async {
    final a = FakeProvider([
      [_empty],
      [_empty]
    ]);
    final b = FakeProvider([
      [_empty],
      [_empty]
    ]);
    final agent = _agent(
      RetryingProvider(PooledProvider([a, b], cooldown: Duration.zero),
          maxRetries: 1),
      FakeAgentSink(),
    );

    await agent.run(history: [], userInput: 'hi');

    expect(a.calls, hasLength(2));
    expect(b.calls, hasLength(2));
    expect(agent.abortedReason, contains('empty completion'));
  });

  test('cancelling after the pool retry notice prevents another request',
      () async {
    final member = FakeProvider([
      [_empty],
      [_ok]
    ]);
    final provider =
        RetryingProvider(PooledProvider([member], cooldown: Duration.zero));
    final retryNotice = Completer<void>();
    final sub =
        provider.send(system: 'sys', messages: [], tools: []).listen((event) {
      if (event is StreamNotice && event.text.contains('retry 1/3')) {
        retryNotice.complete();
      }
    });
    addTearDown(sub.cancel);
    await retryNotice.future.timeout(const Duration(seconds: 2));
    await sub.cancel();
    // First retry delay is at most 250 ms; allow it to elapse after cancel.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(member.calls, hasLength(1));
  });

  for (final pooled in [false, true]) {
    test(
        'reasoning token exhaustion is diagnosed without resending (pool: $pooled)',
        () async {
      final client = _ReasoningClient();
      final adapter =
          OpenAiCompatibleAdapter(apiKey: '', model: 'fixture', client: client);
      final spare = FakeProvider([
        [_ok]
      ]);
      final provider = RetryingProvider(
        pooled
            ? PooledProvider([adapter, spare], cooldown: Duration.zero)
            : adapter,
      );
      addTearDown(provider.close);
      final sink = FakeAgentSink();
      final agent = _agent(provider, sink);
      final history = <Message>[];

      await agent.run(history: history, userInput: 'hi');

      expect(client.bodies, hasLength(1));
      expect(spare.calls, isEmpty,
          reason: 'a terminal stop must not trigger failover');
      expect(agent.abortedKind, AbortedKind.providerTerminal);
      expect(agent.abortedReason, contains('output token limit'));
      expect(agent.abortedReason, contains('finish reason: length'));
      expect(agent.abortedReason, contains('--max-tokens'));
      expect(sink.notices.any((n) => n.message.contains('retry 1/')), isFalse);
      expect(history.where((m) => m.role == Role.assistant), isEmpty);
    });
  }

  for (final reason in ['max_tokens', 'content_filter', 'refusal', 'safety']) {
    test('empty $reason completion survives the pool and is not retried',
        () async {
      final member = FakeProvider([
        [
          MessageComplete(content: const [TextBlock('  ')], stopReason: reason)
        ],
      ]);
      final spare = FakeProvider([
        [_ok]
      ]);
      final agent = _agent(
        RetryingProvider(
            PooledProvider([member, spare], cooldown: Duration.zero)),
        FakeAgentSink(),
      );

      await agent.run(history: [], userInput: 'hi');

      expect(member.calls, hasLength(1));
      expect(spare.calls, isEmpty);
      expect(agent.abortedReason, contains('finish reason: $reason'));
      expect(agent.abortedReason,
          contains(reason == 'max_tokens' ? 'output token limit' : 'filtered'));
    });
  }

  for (final reason in ['length', 'content_filter']) {
    test('standalone agent does not mark $reason as transient', () async {
      final registry = scriptedRegistry({
        'a': [MessageComplete(content: const [], stopReason: reason)],
      });
      final scheduler = testScheduler(registry, pipeline: defaultTestPipeline);
      addTearDown(scheduler.dispose);
      final result = await scheduler.runStandalone(
        systemPrompt: 'sys',
        task: 'hi',
        parentReference: 'a/a-model',
        sink: FakeAgentSink(),
        includeDelegate: false,
      );
      expect(result.isError, isTrue);
      expect(result.transient, isFalse);
    });
  }
}
