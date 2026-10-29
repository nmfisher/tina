// Server-side web search on the OpenAI-compatible wire: the request
// carries a `web_search` entry beside the function tools, mid-stream
// `delta.web_search` frames surface as notices (never transcript text),
// and the capability is off everywhere it was not verified. No network,
// no credentials — recorded bytes through the injected endpoint.
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';

import 'helpers.dart';

const _queryTurn = [
  Message(role: Role.user, content: [TextBlock('what changed in dart 3.9?')]),
];

/// A plain streaming answer, plus one GLM-style web-search delta frame.
HttpResponse _answeredWithSearch() => sseResponse(200, [
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {
                  'web_search': [
                    {
                      'title': 'Dart 3.9 release notes',
                      'url': 'https://dart.dev/guides/language/evolution',
                    }
                  ]
                }
              }
            ]
          })}\n\n',
      'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'Dart 3.9 shipped.'},
                'finish_reason': 'stop'
              }
            ]
          })}\n\n',
      'data: [DONE]\n\n',
    ]);

Stream<StreamEvent> _send(LlmProvider provider) =>
    provider.send(system: '', messages: _queryTurn, tools: const []);

void main() {
  group('generation options', () {
    test('web search appends a non-function entry beside function tools', () {
      final body = GenerationOptions(webSearch: true).openAi(
        chatCompletionsBody(
          model: 'glm-5.3',
          system: 'be brief',
          messages: _queryTurn,
          tools: const [
            ToolSchema(name: 'read', description: 'read a file',
                inputSchema: {'type': 'object'}),
          ],
        ),
      );
      final tools = body['tools'] as List;
      expect(tools, hasLength(2));
      final byType = {
        for (final t in tools.cast<Map>()) t['type'] as String: t,
      };
      expect(byType.keys, unorderedEquals(['function', 'web_search']));
      expect(byType['web_search'], {
        'type': 'web_search',
        'web_search': {'enable': true},
      });
      expect(byType['function']!['function'], containsPair('name', 'read'));
    });

    test('web search creates the tools list when no function tools exist', () {
      final body = GenerationOptions(webSearch: true).openAi(
        chatCompletionsBody(
            model: 'glm-5.3',
            system: '',
            messages: _queryTurn,
            tools: const []),
      );
      expect(body['tools'], [
        {
          'type': 'web_search',
          'web_search': {'enable': true},
        }
      ]);
    });

    test('web search off leaves the request untouched', () {
      final body = GenerationOptions().openAi(chatCompletionsBody(
          model: 'm', system: '', messages: _queryTurn, tools: const []));
      expect(body.containsKey('tools'), isFalse);
    });

    test('the other wires ignore the option', () {
      const body = <String, dynamic>{};
      expect(GenerationOptions(webSearch: true).anthropic(Map.of(body)),
          isNot(contains('tools')));
      expect(GenerationOptions(webSearch: true).gemini(Map.of(body)),
          isNot(contains('tools')));
    });
  });

  group('on the wire', () {
    test('glm streams search deltas as notices and still completes', () async {
      final endpoint = ReplayEndpoint(_answeredWithSearch());
      final provider = OpenAiCompatibleProvider(
        model: 'glm-5.3',
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        tokenFrom: () => 'test',
        endpoint: endpoint,
        generation: const GenerationOptions(webSearch: true),
      );
      addTearDown(provider.close);
      final events = await _send(provider).toList();
      expect(events.whereType<StreamError>(), isEmpty);
      final notices = events.whereType<StreamNotice>().toList();
      expect(notices, hasLength(1));
      expect(notices.single.text, contains('web search: 1 result'));
      final completion = events.whereType<MessageComplete>().single;
      expect(
        completion.content.whereType<TextBlock>().single.text,
        'Dart 3.9 shipped.',
      );
      // The search frame named no tool call, so none was fabricated.
      expect(completion.content.whereType<ToolUseBlock>(), isEmpty);
    });

    test('search deltas without the option still notice, never crash',
        () async {
      final endpoint = ReplayEndpoint(_answeredWithSearch());
      final provider = OpenAiCompatibleProvider(
        model: 'glm-5.3',
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        tokenFrom: () => 'test',
        endpoint: endpoint,
      );
      addTearDown(provider.close);
      final events = await _send(provider).toList();
      expect(events.whereType<StreamError>(), isEmpty);
      expect(events.whereType<StreamNotice>(), hasLength(1));
    });

    test('the descriptor capability is verified-on only where checked', () {
      expect(descriptorById('glm')!.supportsWebSearch, isTrue);
      expect(descriptorById('deepseek')!.supportsWebSearch, isTrue);
      for (final id in ['anthropic', 'openai', 'gemini', 'openrouter']) {
        expect(descriptorById(id)!.supportsWebSearch, isFalse,
            reason: '$id was not verified for web search');
      }
    });

    test('a plain answer produces no notice and no diagnostics drift',
        () async {
      final endpoint = ReplayEndpoint(sseResponse(200, [
        'data: ${jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': 'hi'},
                  'finish_reason': 'stop'
                }
              ]
            })}\n\n',
        'data: [DONE]\n\n',
      ]));
      final provider = OpenAiCompatibleProvider(
        model: 'm',
        baseUrl: 'https://api.openai.com/v1',
        tokenFrom: () => 'test',
        endpoint: endpoint,
      );
      addTearDown(provider.close);
      final events = await _send(provider).toList();
      expect(events.whereType<StreamNotice>(), isEmpty);
      expect(events.whereType<StreamError>(), isEmpty);
    });
  });
}
