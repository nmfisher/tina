import 'dart:convert';
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';
import 'helpers.dart';

String frame(Map<String, Object?> delta, {String? finish}) =>
    'data: ${jsonEncode({
          'choices': [
            {'index': 0, 'delta': delta, 'finish_reason': finish}
          ]
        })}\n\n';

void main() {
  for (final finish in ['length', 'stop', 'content_filter']) {
    test('reasoning-only $finish preserves diagnostics and usage', () async {
      final endpoint = ReplayEndpoint(sseResponse(200, [
        frame({'reasoning_content': 'thinking'}, finish: finish),
        'data: {"choices":[],"usage":{"prompt_tokens":123,"completion_tokens":8192}}\n\n',
        'data: [DONE]\n\n',
      ]));
      final provider = OpenAiCompatibleProvider(
          model: 'test-model',
          baseUrl: 'http://local/v1',
          tokenFrom: () => 'fake',
          endpoint: endpoint,
          generation: const GenerationOptions(maxOutputTokens: 32768));
      final events =
          await provider.send(system: '', messages: [], tools: []).toList();
      final error = events.whereType<StreamError>().single;
      expect(error.error.toString(), contains('finish_reason=$finish'));
      expect(error.error.toString(), contains('requested max_output=32768'));
      expect(error.error.toString(), contains('reasoning chars=8'));
      expect(error.usage!.outputTokens, 8192);
      expect(
          error.providerCode,
          finish == 'length'
              ? 'output_limit'
              : finish == 'stop'
                  ? 'reasoning_only'
                  : 'content_filter');
      expect(events.whereType<MessageComplete>(), isEmpty);
    });
  }
  test('truncated tool arguments never become an executable completion',
      () async {
    final endpoint = ReplayEndpoint(sseResponse(200, [
      frame({
        'tool_calls': [
          {
            'index': 0,
            'id': 'call',
            'function': {'name': 'write', 'arguments': '{"filePath":'}
          }
        ]
      }, finish: 'length'),
      'data: [DONE]\n\n',
    ]));
    final events = await OpenAiCompatibleProvider(
            model: 'test',
            baseUrl: 'http://local/v1',
            tokenFrom: () => 'fake',
            endpoint: endpoint)
        .send(system: '', messages: [], tools: []).toList();
    expect(events.whereType<MessageComplete>(), isEmpty);
    expect(events.whereType<StreamError>().single.providerCode, 'output_limit');
  });
  test(
      'reasoning metadata does not erase tool calls and answers on next request',
      () {
    final messages = chatCompletionsMessages([
      const Message(role: Role.assistant, reasoning: [
        ReasoningBlock('private')
      ], content: [
        TextBlock('answer'),
        ToolUseBlock(id: 'call', name: 'read', input: {'filePath': 'a'})
      ]),
      const Message(
          role: Role.user,
          content: [ToolResultBlock(toolUseId: 'call', content: 'file')]),
    ]);
    expect(messages, hasLength(2));
    expect(messages.first['content'], 'answer');
    expect(messages.first['tool_calls'], hasLength(1));
    expect(jsonEncode(messages), isNot(contains('private')));
  });
}
