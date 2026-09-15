import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_http.dart';

String _chunk(Map<String, dynamic> delta, {String? finish, Map? usage}) =>
    'data: ${jsonEncode({
          'choices': [
            {'delta': delta, 'finish_reason': finish}
          ],
          if (usage != null) 'usage': usage,
        })}\n\n';

void main() {
  for (final effort in [null, 'low', 'high', 'max']) {
    test(
        'GLM-5.3 Flash effort $effort reaches the wire without disabling thinking',
        () async {
      final capture = CapturedRequest();
      final provider = OpenAiCompatibleAdapter(
          apiKey: '',
          model: 'glm-5.3-flash',
          reasoningEffort: effort,
          maxTokens: 12345,
          client: capture.client);
      addTearDown(provider.close);
      await provider.send(system: 'sys', messages: [], tools: []).drain<void>();
      final body = jsonDecode(capture.body!) as Map;
      expect(body['reasoning_effort'], effort);
      expect(body.containsKey('reasoning_effort'), effort != null);
      expect(body.containsKey('thinking'), isFalse);
      expect(body['max_tokens'], 12345);
    });
  }

  test('explicit effort overrides model extras without mutating them',
      () async {
    final capture = CapturedRequest();
    final extras = {'reasoning_effort': 'max', 'temperature': 0.7};
    final provider = OpenAiCompatibleAdapter(
        apiKey: '',
        model: 'glm-5.3',
        reasoningEffort: 'low',
        extraBody: extras,
        client: capture.client);
    addTearDown(provider.close);
    await provider.send(system: '', messages: [], tools: []).drain<void>();
    final body = jsonDecode(capture.body!) as Map;
    expect(body['reasoning_effort'], 'low');
    expect(body['temperature'], 0.7);
    expect(extras['reasoning_effort'], 'max');
  });

  test('invalid GLM-5.3 effort fails before sending even after model swap',
      () async {
    final capture = CapturedRequest();
    final provider = OpenAiCompatibleAdapter(
        apiKey: '',
        model: 'glm-5.2',
        reasoningEffort: 'none',
        client: capture.client);
    addTearDown(provider.close);
    provider.model = 'glm-5.3-FLASH';
    final events =
        await provider.send(system: '', messages: [], tools: []).toList();
    expect(events.single, isA<StreamError>());
    expect((events.single as StreamError).error.toString(),
        contains('requires reasoning'));
    expect(capture.body, isNull);
  });

  test(
      'reasoning status and diagnostics do not become answer text or extra spend',
      () async {
    final provider = OpenAiCompatibleAdapter(
        apiKey: '',
        model: 'glm-5.3-flash',
        maxTokens: 40,
        reasoningEffort: 'low',
        client: ScriptedSseClient(
            _chunk({'reasoning_content': 'private reasoning'}) +
                _chunk({'reasoning_content': 'more private reasoning'}) +
                _chunk({'content': 'Answer'},
                    finish: 'stop',
                    usage: {
                      'prompt_tokens': 10,
                      'completion_tokens': 30,
                      'completion_tokens_details': {'reasoning_tokens': 25},
                    }) +
                'data: [DONE]\n\n'));
    addTearDown(provider.close);
    final events =
        await provider.send(system: '', messages: [], tools: []).toList();
    final reasoning = events.whereType<ReasoningDelta>().toList();
    expect(reasoning, hasLength(2));
    expect(reasoning.first.startsBlock, isTrue);
    expect(reasoning.last.startsBlock, isFalse);
    expect(reasoning.map((e) => e.text).join(),
        'private reasoningmore private reasoning');
    expect(events.whereType<ReasoningEnd>().single.complete, isTrue);
    expect(events.whereType<StreamNotice>(), isEmpty);
    expect(events.whereType<TextDelta>().single.text, 'Answer');
    final complete = events.whereType<MessageComplete>().single;
    expect((complete.content.single as TextBlock).text, 'Answer');
    expect(complete.usage!.outputTokens, 30);
    expect(complete.diagnostics!.reasoningObserved, isTrue);
    expect(complete.diagnostics!.reasoningTokens, 25);
    expect(complete.diagnostics!.outputLimit, 40);
    expect(
        classifyEmptyCompletion(complete.content, complete.stopReason,
            reasoningObserved: true),
        isNull);
  });

  test(
      'reasoning token details alone can diagnose a withheld reasoning channel',
      () async {
    final provider = OpenAiCompatibleAdapter(
        apiKey: '',
        model: 'glm-5.3',
        extraBody: const {'max_tokens': 8192},
        client: ScriptedSseClient(_chunk({},
                finish: 'length',
                usage: {
                  'prompt_tokens': 10,
                  'completion_tokens': 8192,
                  'completion_tokens_details': {'reasoning_tokens': 8192},
                }) +
            'data: [DONE]\n\n'));
    addTearDown(provider.close);
    final events =
        await provider.send(system: '', messages: [], tools: []).toList();
    final complete = events.whereType<MessageComplete>().single;
    expect(complete.content, isEmpty);
    expect(complete.diagnostics!.reasoningObserved, isTrue);
    expect(complete.diagnostics!.outputLimit, 8192);
  });

  test('native wire providers retain effort for a warning without throwing',
      () {
    final registry = builtinRegistry(env: {});
    for (final ref in [
      'anthropic/claude-sonnet-4-6',
      'gemini/gemini-2.5-pro',
      'tencent/hy3'
    ]) {
      final provider = registry.build(ref, reasoningEffort: 'low');
      addTearDown(provider.close);
      expect(
          provider is AnthropicProvider
              ? provider.reasoningEffort
              : (provider as GeminiProvider).reasoningEffort,
          'low');
    }
  });
}
