import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_http.dart';

void main() {
  group('GeminiProvider request encoding', () {
    test('systemInstruction, user/model roles, tools, generationConfig', () async {
      final cap = CapturedRequest();
      final provider = GeminiProvider(
          apiKey: 'key', model: 'gemini-2.5-pro', client: cap.client);
      await provider
          .send(
            system: 'you are tina',
            messages: const [
              Message(role: Role.user, content: [TextBlock('hi')]),
              Message(role: Role.assistant, content: [TextBlock('hello')]),
            ],
            tools: const [
              ToolSchema(
                  name: 'bash', description: 'run', inputSchema: {'type': 'object'}),
            ],
          )
          .toList();

      expect(
          cap.url,
          'https://generativelanguage.googleapis.com/v1beta/'
          'models/gemini-2.5-pro:streamGenerateContent?alt=sse');

      final body = jsonDecode(cap.body!) as Map<String, dynamic>;
      expect((body['systemInstruction'] as Map)['parts'].first['text'],
          'you are tina');
      final contents = body['contents'] as List;
      expect((contents[0] as Map)['role'], 'user');
      expect((contents[1] as Map)['role'], 'model'); // assistant → model
      expect(
          (body['tools'] as List).first['functionDeclarations'], hasLength(1));
      expect(body['generationConfig']['maxOutputTokens'], 8192);
    });

    test('omits systemInstruction when system is empty', () async {
      final cap = CapturedRequest();
      final provider = GeminiProvider(
          apiKey: 'key', model: 'gemini-2.5-pro', client: cap.client);
      await provider.send(
        system: '',
        messages: const [Message(role: Role.user, content: [TextBlock('hi')])],
        tools: const [],
      ).toList();
      final body = jsonDecode(cap.body!) as Map<String, dynamic>;
      expect(body.containsKey('systemInstruction'), isFalse);
    });

    test('encodes tool_use as functionCall and result as functionResponse '
        'with the name resolved from the call id', () async {
      final cap = CapturedRequest();
      final provider = GeminiProvider(
          apiKey: 'key', model: 'gemini-2.5-pro', client: cap.client);
      await provider.send(
        system: 'sys',
        messages: const [
          Message(role: Role.user, content: [TextBlock('list files')]),
          Message(role: Role.assistant, content: [
            ToolUseBlock(id: 'call_1', name: 'bash', input: {'command': 'ls'}),
          ]),
          Message(role: Role.user, content: [
            ToolResultBlock(toolUseId: 'call_1', content: 'file.txt'),
          ]),
        ],
        tools: const [],
      ).toList();

      final contents =
          (jsonDecode(cap.body!) as Map<String, dynamic>)['contents'] as List;
      final modelTurn = contents[1] as Map;
      expect(modelTurn['role'], 'model');
      final fc = (modelTurn['parts'].first as Map)['functionCall'] as Map;
      expect(fc['name'], 'bash');
      expect(fc['args'], {'command': 'ls'});

      final resTurn = contents[2] as Map;
      expect(resTurn['role'], 'user');
      final fres = (resTurn['parts'].first as Map)['functionResponse'] as Map;
      // Name resolved from id 'call_1' → 'bash' via the prior assistant turn.
      expect(fres['name'], 'bash');
    });
  });

  group('GeminiProvider response parsing', () {
    test('streams text deltas and emits MessageComplete with usage', () async {
      final sse = [
        'data: ${jsonEncode({
              "candidates": [
                {
                  "content": {
                    "role": "model",
                    "parts": [
                      {"text": "Hel"},
                      {"text": "lo"}
                    ]
                  },
                  "finishReason": "STOP"
                }
              ],
              "usageMetadata": {
                "promptTokenCount": 5,
                "candidatesTokenCount": 2
              }
            })}',
        '',
      ].join('\n');
      final provider = GeminiProvider(
          apiKey: 'k', model: 'gemini-2.5-pro', client: ScriptedSseClient(sse));
      final events = await provider
          .send(system: '', messages: const [], tools: const []).toList();

      expect(events.whereType<TextDelta>().map((e) => e.text).toList(),
          ['Hel', 'lo']);
      final complete = events.whereType<MessageComplete>().single;
      expect((complete.content.single as TextBlock).text, 'Hello');
      expect(complete.stopReason, 'end_turn');
      expect(complete.usage!.inputTokens, 5);
      expect(complete.usage!.outputTokens, 2);
    });

    test('parses a functionCall into a tool call with tool_use stop reason',
        () async {
      final sse = [
        'data: ${jsonEncode({
              "candidates": [
                {
                  "content": {
                    "role": "model",
                    "parts": [
                      {
                        "functionCall": {"name": "bash", "args": {"command": "ls"}}
                      }
                    ]
                  }
                }
              ]
            })}',
        '',
      ].join('\n');
      final provider = GeminiProvider(
          apiKey: 'k', model: 'gemini-2.5-pro', client: ScriptedSseClient(sse));
      final events = await provider
          .send(system: '', messages: const [], tools: const []).toList();

      expect(events.whereType<ToolCallStart>().single.name, 'bash');
      final complete = events.whereType<MessageComplete>().single;
      final use = complete.content.whereType<ToolUseBlock>().single;
      expect(use.name, 'bash');
      expect(use.input, {'command': 'ls'});
      expect(complete.stopReason, 'tool_use');
    });

    test('maps MAX_TOKENS to max_tokens', () async {
      final sse = [
        'data: ${jsonEncode({
              "candidates": [
                {
                  "content": {"role": "model", "parts": [{"text": "cut"}]},
                  "finishReason": "MAX_TOKENS"
                }
              ]
            })}',
        '',
      ].join('\n');
      final provider = GeminiProvider(
          apiKey: 'k', model: 'gemini-2.5-pro', client: ScriptedSseClient(sse));
      final events = await provider
          .send(system: '', messages: const [], tools: const []).toList();
      expect(events.whereType<MessageComplete>().single.stopReason, 'max_tokens');
    });
  });

  group('error handling', () {
    test('non-200 yields a StreamError with the humanized body', () async {
      final provider = GeminiProvider(
        apiKey: 'k',
        model: 'gemini-2.5-pro',
        client: ScriptedSseClient(
          jsonEncode({'error': {'message': 'bad request'}}),
          status: 400,
        ),
      );
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();
      expect(events.whereType<StreamError>().single.error,
          'Gemini 400: bad request');
    });

    test('an empty SSE stream emits an empty MessageComplete', () async {
      final provider = GeminiProvider(
        apiKey: 'k',
        model: 'gemini-2.5-pro',
        client: ScriptedSseClient(''),
      );
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();
      final complete = events.whereType<MessageComplete>().single;
      expect(complete.content, isEmpty);
      expect(complete.stopReason, 'end_turn');
      expect(complete.usage, isNull);
    });
  });
}
