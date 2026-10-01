import 'dart:convert';
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';
import 'helpers.dart';

const output = JsonOutputSchema(name: 'permission_decision', schema: {
  'type': 'object',
  'properties': {
    'decision': {
      'type': 'string',
      'enum': ['ALLOW', 'DENY']
    }
  },
  'required': ['decision'],
  'additionalProperties': false,
});
const verdict = '{"decision":"ALLOW"}';
const messages = [
  Message(role: Role.user, content: [TextBlock('review ls')])
];

HttpResponse reply(ProviderWire wire) => sseResponse(
    200,
    switch (wire) {
      ProviderWire.anthropic => [
          sseFrame('content_block_start', {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''}
          }),
          sseFrame('content_block_delta', {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': verdict}
          }),
          sseFrame('message_delta', {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
            'usage': {'output_tokens': 7}
          }),
          sseFrame('message_stop', {'type': 'message_stop'}),
        ],
      ProviderWire.openAiCompatible => [
          'data: ${jsonEncode({
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': verdict},
                    'finish_reason': 'stop'
                  }
                ]
              })}\n\n',
          'data: [DONE]\n\n',
        ],
      ProviderWire.gemini => [
          'data: ${jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': verdict}
                      ]
                    },
                    'finishReason': 'STOP'
                  }
                ]
              })}\n\n',
        ],
    });

void main() {
  for (final wire in ProviderWire.values) {
    test('$wire constrains final JSON and preserves generation settings',
        () async {
      final endpoint = ReplayEndpoint(reply(wire));
      const generation = GenerationOptions(
          maxOutputTokens: 4096,
          reasoningEffort: 'low',
          openAiOutputField: 'max_completion_tokens');
      final LlmProvider provider = switch (wire) {
        ProviderWire.anthropic => AnthropicProvider(
            model: 'claude-sonnet-4-6',
            tokenFrom: () => 'test',
            endpoint: endpoint,
            generation: generation),
        ProviderWire.openAiCompatible => OpenAiCompatibleProvider(
            model: 'gpt-4o',
            baseUrl: 'https://api.openai.com/v1',
            tokenFrom: () => 'test',
            endpoint: endpoint,
            generation: generation),
        ProviderWire.gemini => GeminiProvider(
            model: 'gemini-2.5-flash',
            tokenFrom: () => 'test',
            endpoint: endpoint,
            generation: generation),
      };
      addTearDown(provider.close);
      final events = await (provider as StructuredOutputProvider)
          .sendStructured(
              system: 'Return a JSON decision.',
              messages: messages,
              output: output)
          .toList();
      expect(events.whereType<StreamError>(), isEmpty);
      expect(events.whereType<MessageComplete>().single.content.single.toJson(),
          const TextBlock(verdict).toJson());
      expect(endpoint.body, isNot(contains('tools')));
      switch (wire) {
        case ProviderWire.anthropic:
          expect(endpoint.body!['max_tokens'], 4096);
          expect(endpoint.body!['output_config'], {
            'effort': 'low',
            'format': {'type': 'json_schema', 'schema': output.schema}
          });
        case ProviderWire.openAiCompatible:
          expect(endpoint.body!['response_format'], {
            'type': 'json_schema',
            'json_schema': {
              'name': output.name,
              'strict': true,
              'schema': output.schema
            }
          });
          expect(endpoint.body!['max_completion_tokens'], 4096);
          expect(endpoint.body!['reasoning_effort'], 'low');
        case ProviderWire.gemini:
          expect(endpoint.body!['generationConfig'], {
            'maxOutputTokens': 4096,
            'thinkingConfig': {'thinkingLevel': 'LOW'},
            'responseFormat': {
              'text': {'mimeType': 'application/json', 'schema': output.schema}
            }
          });
      }
    });
  }
  for (final base in [
    'https://api.z.ai/api/coding/paas/v4',
    'https://open.bigmodel.cn/api/paas/v4'
  ]) {
    test('$base uses documented JSON mode with schema supplied in prompt',
        () async {
      final endpoint = ReplayEndpoint(reply(ProviderWire.openAiCompatible));
      final provider = OpenAiCompatibleProvider(
          model: 'glm-5.3-flashx',
          baseUrl: base,
          tokenFrom: () => 'test',
          endpoint: endpoint);
      addTearDown(provider.close);
      await provider
          .sendStructured(
              system: 'Review the request.', messages: messages, output: output)
          .drain<void>();
      expect(endpoint.body!['response_format'], {'type': 'json_object'});
      expect(endpoint.body!['messages'][0]['content'],
          contains(jsonEncode(output.schema)));
      expect(endpoint.body!['messages'][1]['content'], 'review ls');
      await provider.send(
          system: 'Ordinary agent turn.',
          messages: messages,
          tools: []).drain<void>();
      expect(endpoint.body, isNot(contains('response_format')));
      expect(endpoint.body!['messages'][0]['content'], 'Ordinary agent turn.');
    });
  }
  test('unsupported schema stays an error; no unconstrained retry', () async {
    final endpoint = ReplayEndpoint(sseResponse(400, [
      jsonEncode({
        'error': {'message': 'response_format json_schema is unsupported'},
      })
    ]));
    final provider = OpenAiCompatibleProvider(
        model: 'custom',
        baseUrl: 'https://example.test/v1',
        tokenFrom: () => 'test',
        endpoint: endpoint);
    addTearDown(provider.close);
    final events = await provider
        .sendStructured(system: '', messages: messages, output: output)
        .toList();
    expect(events.whereType<MessageComplete>(), isEmpty);
    expect(events.whereType<StreamError>().single.statusCode, 400);
    expect(endpoint.body!['response_format']['json_schema']['strict'], true);
  });
}
