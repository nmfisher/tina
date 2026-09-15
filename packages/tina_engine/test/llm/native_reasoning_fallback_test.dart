import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

String _sse(List<Map<String, Object?>> events) =>
    events.map((event) => 'data: ${jsonEncode(event)}\n\n').join();

void main() {
  for (final wire in ['Anthropic', 'Gemini']) {
    for (final effort in [null, 'high']) {
      test('$wire effort $effort answers and warns only once when unsupported',
          () async {
        final requests = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          final events = wire == 'Anthropic'
              ? <Map<String, Object?>>[
                  {
                    'type': 'message_start',
                    'message': {
                      'usage': {'input_tokens': 1},
                    },
                  },
                  {
                    'type': 'content_block_start',
                    'index': 0,
                    'content_block': {'type': 'text', 'text': ''},
                  },
                  {
                    'type': 'content_block_delta',
                    'index': 0,
                    'delta': {'type': 'text_delta', 'text': 'OK'},
                  },
                  {
                    'type': 'message_delta',
                    'delta': {'stop_reason': 'end_turn'},
                    'usage': {'output_tokens': 1},
                  },
                  {'type': 'message_stop'},
                ]
              : <Map<String, Object?>>[
                  {
                    'candidates': [
                      {
                        'content': {
                          'role': 'model',
                          'parts': [
                            {'text': 'OK'},
                          ],
                        },
                        'finishReason': 'STOP',
                      },
                    ],
                  },
                ];
          return http.Response(_sse(events), 200,
              headers: {'content-type': 'text/event-stream'});
        });
        final LlmProvider provider = wire == 'Anthropic'
            ? AnthropicProvider(
                apiKey: 'test',
                model: 'glm-5.3-flash',
                reasoningEffort: effort,
                client: client)
            : GeminiProvider(
                apiKey: 'test',
                model: 'gemini-2.5-pro',
                reasoningEffort: effort,
                client: client);
        addTearDown(provider.close);

        for (var attempt = 0; attempt < 2; attempt++) {
          final events = await provider
              .send(system: 'sys', messages: [], tools: []).toList();
          expect(events.whereType<StreamError>(), isEmpty);
          final complete = events.whereType<MessageComplete>().single;
          expect((complete.content.single as TextBlock).text, 'OK');
          final notices = events.whereType<StreamNotice>();
          if (effort != null && attempt == 0) {
            expect(notices.single.text, contains('--reasoning-effort high'));
            expect(notices.single.text, contains('on the $wire wire'));
            expect(notices.single.text, contains('using the provider default'));
          } else {
            expect(notices, isEmpty);
          }
        }
        expect(requests, hasLength(2));
        for (final body in requests) {
          expect(body, isNot(contains('reasoning_effort')));
          expect(body, isNot(contains('thinking')));
          expect(body, isNot(contains('output_config')));
          if (wire == 'Gemini') {
            expect(body['generationConfig'],
                {'maxOutputTokens': ProviderRegistry.defaultMaxTokens});
          }
        }
      });
    }
  }
}
