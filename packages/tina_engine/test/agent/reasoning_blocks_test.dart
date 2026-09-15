import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_http.dart';
import '../helpers/fake_provider.dart';

const _answer = MessageComplete(content: [TextBlock('answer')], stopReason: 'stop');

Agent _agent(LlmProvider provider, FakeAgentSink sink) => Agent(
    provider: provider, tools: ToolRegistry([]), sink: sink, system: 'sys',
    policy: PermissionPolicy(), asker: (_) async => PermissionResponse.denyOnce);

void main() {
  test('many streamed chunks render one collapsed row and retain exact text', () async {
    final sink = FakeAgentSink();
    final outcome = await const ProviderStreamConsumer().consume(Stream.fromIterable([
      const ReasoningDelta('first\n', startsBlock: true),
      const ReasoningDelta('第二步'),
      const ReasoningEnd(),
      const TextDelta('answer'), _answer,
    ]), sink: sink);
    expect(sink.notices, hasLength(1));
    expect(sink.notices.single.message.trim(), kReasoningCollapsedLabel);
    expect(sink.notices.single.kind, NoticeKind.info);
    expect(sink.texts, ['answer']);
    expect(outcome.reasoning.single.text, 'first\n第二步');
    expect(outcome.reasoning.single.complete, isTrue);
  });

  test('cancellation persists partial reasoning before run returns', () async {
    final provider = HoldProvider();
    final sink = FakeAgentSink();
    final agent = _agent(provider, sink);
    final history = <Message>[];
    final saved = <Message>[];
    agent.onHistoryAppend = (message) async { saved.add(message); };
    final cancel = Completer<void>();
    final run = agent.run(history: history, userInput: 'hi', cancelSignal: cancel.future);
    // HoldProvider creates its controller when send is invoked.
    await Future<void>.delayed(Duration.zero);
    provider.controller.add(const ReasoningDelta('partial thought', startsBlock: true));
    await Future<void>.delayed(Duration.zero);
    cancel.complete();
    await run.timeout(const Duration(seconds: 2));
    final record = saved.singleWhere((m) => m.isReasoningOnly);
    expect(record.reasoning.single.text, 'partial thought');
    expect(record.reasoning.single.complete, isFalse);
    expect(history, contains(record));
    expect(sink.texts, isEmpty);
  });

  test('pool failover keeps separate partial and complete reasoning blocks', () async {
    final a = FakeProvider([[
      const ReasoningDelta('attempt one', startsBlock: true),
      const StreamError('failed', transient: true),
    ]]);
    final b = FakeProvider([[
      const ReasoningDelta('attempt two', startsBlock: true),
      const ReasoningEnd(), _answer,
    ]]);
    final pool = PooledProvider([a, b], cooldown: Duration.zero);
    addTearDown(pool.close);
    final sink = FakeAgentSink();
    final outcome = await const ProviderStreamConsumer().consume(
        pool.send(system: '', messages: [], tools: []), sink: sink);
    expect(outcome.error, isNull);
    expect(outcome.reasoning.map((b) => b.text), ['attempt one', 'attempt two']);
    expect(outcome.reasoning.map((b) => b.complete), [false, true]);
    expect(sink.notices.where((n) => n.message.contains(kReasoningCollapsedLabel)), hasLength(2));
  });

  test('successful next attempt without reasoning does not complete prior partial block', () async {
    final outcome = await const ProviderStreamConsumer().consume(Stream.fromIterable([
      const ReasoningDelta('failed attempt', startsBlock: true),
      const StreamNotice('retry'), _answer,
    ]), sink: FakeAgentSink());
    expect(outcome.reasoning.single.complete, isFalse);
  });

  test('agent retains reasoning but excludes it from later model requests and estimates', () async {
    final provider = FakeProvider([
      [const ReasoningDelta('retained only locally', startsBlock: true),
        const ReasoningEnd(), _answer],
      [_answer],
    ]);
    final agent = _agent(provider, FakeAgentSink());
    final history = <Message>[];
    await agent.run(history: history, userInput: 'hi');
    expect(history.where((m) => m.isReasoningOnly), hasLength(1));
    final before = TokenBudget.estimateInputTokens('', history, []);
    final visible = history.where((m) => !m.isReasoningOnly).toList();
    expect(TokenBudget.estimateInputTokens('', visible, []), before);
    await agent.run(history: history, userInput: 'continue');
    expect(provider.calls.last.messages.any((m) => m.isReasoningOnly), isFalse);
    expect(agent.abortedReason, isNull);
  });

  test('JSONL restore retains full text while replay renders only collapsed rows', () async {
    final dir = await Directory.systemTemp.createTemp('tina-reasoning-');
    addTearDown(() => dir.delete(recursive: true));
    final store = JsonlSessionStore(dir);
    final sid = await store.createSession(providerId: 'fixture');
    final cid = await store.createConversation(sid);
    const message = Message(role: Role.assistant, content: [], reasoning: [
      ReasoningBlock('full private reasoning\nwith lines', complete: false),
    ]);
    await store.append(sid, cid, message);
    final loaded = await store.loadConversation(sid, cid);
    expect(loaded.single.toJson(), message.toJson());
    final host = FakeHostInterface();
    replayHistory(host, loaded);
    expect(host.sink.texts, isEmpty);
    expect(host.notices.single, contains(kReasoningCollapsedLabel));
    expect(host.notices.single, contains('partial'));
    expect(host.notices.single, isNot(contains('private reasoning')));
  });

  for (final wire in ['openai', 'anthropic', 'gemini']) {
    test('$wire never sends reasoning metadata or empty transcript-only messages', () async {
      final capture = CapturedRequest();
      final provider = switch (wire) {
        'openai' => OpenAiCompatibleAdapter(apiKey: '', model: 'fixture', client: capture.client),
        'anthropic' => AnthropicProvider(apiKey: '', model: 'fixture', client: capture.client),
        _ => GeminiProvider(apiKey: '', model: 'fixture', client: capture.client),
      };
      addTearDown(provider.close);
      await provider.send(system: '', messages: const [
        Message(role: Role.user, content: [TextBlock('hi')]),
        Message(role: Role.assistant, content: [], reasoning: [ReasoningBlock('secret reasoning')]),
        Message(role: Role.assistant, content: [TextBlock('answer')]),
      ], tools: []).drain<void>();
      expect(capture.body, isNot(contains('secret reasoning')));
      expect(capture.body, isNot(contains('"reasoning"')));
      final body = jsonDecode(capture.body!) as Map;
      final messages = (body[wire == 'gemini' ? 'contents' : 'messages'] as List)
          .where((m) => m['role'] != 'system');
      expect(messages, hasLength(2));
    });
  }
}
