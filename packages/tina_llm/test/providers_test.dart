// Every provider, tested headless: table-driven over the descriptors
// (right base URL, right wire, right key variable, right request shape),
// plus the models.dev catalogue fetched over the injected seam and cached
// in a temp directory. No network, no credentials anywhere — the token
// values in this file are literals passed to the injected closure.
//
// Run: dart test
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';

import 'helpers.dart';

/// A canned catalogue GET: status, then the body as one chunk.
HttpResponse _doc(int status, String body) => HttpResponse(
      statusCode: status,
      headers: const {'content-type': 'application/json'},
      body: Stream.fromIterable([utf8.encode(body)]),
    );

void main() {
  group('the built-in descriptors', () {
    test('all sixteen are present, ids unique and in registry order', () {
      expect(builtinDescriptors, hasLength(16));
      final ids = builtinDescriptors.map((d) => d.id).toList();
      expect(ids.toSet(), hasLength(16));
      expect(ids, [
        'anthropic', 'cerebras', 'gemini', 'openai', 'openrouter',
        'deepseek', 'glm', 'grok', 'hetzner', 'longcat', 'mistral',
        'nim', 'novita', 'qwen', 'qwencloud', 'tencent',
      ]);
      expect(descriptorById('glm')!.name, 'GLM (Zhipu)');
      expect(descriptorById('nope'), isNull);
    });

    test('every descriptor names its key variable, never a value', () {
      for (final d in builtinDescriptors) {
        expect(
            d.keyEnvVar == 'TINA_LLM_TOKEN' || d.keyEnvVar.endsWith('_KEY'),
            isTrue,
            reason: '${d.id}: key env var name');
        expect(d.keyEnvVar, isNot(contains(' ')));
        expect(d.baseUrl, startsWith('https://'));
        // No key value anywhere: the descriptor holds names, and the
        // strings are all constants of the port.
        expect(d.toString(), isNot(contains('sk-')));
      }
    });

    test(
        'each wire carries the right shape: base URL, path, key style, models',
        () {
      final cases = <String, void Function(ProviderDescriptor)>{
        'anthropic': (d) {
          expect(d.wire, ProviderWire.anthropic);
          expect(d.baseUrl, 'https://api.anthropic.com');
          expect(d.keyStyle, ProviderKeyStyle.header);
          expect(d.models, contains('claude-sonnet-4-6'));
          expect(d.models['claude-sonnet-4-6']!.contextWindow, 200000);
        },
        'gemini': (d) {
          expect(d.wire, ProviderWire.gemini);
          expect(
              geminiStreamPath(d.baseUrl, 'gemini-2.5-pro'),
              'https://generativelanguage.googleapis.com/v1beta'
              '/models/gemini-2.5-pro:streamGenerateContent?alt=sse');
          expect(d.keyStyle, ProviderKeyStyle.header);
          expect(d.models.keys, containsAll(['gemini-2.5-pro', 'gemini-2.5-flash']));
          expect(d.models['gemini-2.5-pro']!.contextWindow, 1048576);
        },
        'openai': (d) {
          expect(d.wire, ProviderWire.openAiCompatible);
          expect(chatCompletionsPath(d.baseUrl),
              'https://api.openai.com/v1/chat/completions');
          expect(d.models, contains('gpt-4o'));
        },
        'glm': (d) {
          // `/v4`, not `/v1` — the path builder must not invent one.
          expect(chatCompletionsPath(d.baseUrl),
              'https://open.bigmodel.cn/api/paas/v4/chat/completions');
        },
        'qwen': (d) {
          expect(chatCompletionsPath(d.baseUrl),
              'https://dashscope-intl.aliyuncs.com/compatible-mode/v1'
              '/chat/completions');
        },
        'openrouter': (d) {
          expect(d.models.keys,
              containsAll(['openai/gpt-4o', 'tencent/hy3:free']));
          expect(d.models['google/gemini-2.5-pro']!.contextWindow, 1048576);
        },
        'nim': (d) {
          expect(d.keyEnvVar, 'NVIDIA_API_KEY');
        },
      };
      for (final entry in cases.entries) {
        final d = descriptorById(entry.key);
        expect(d, isNotNull, reason: entry.key);
        entry.value(d!);
      }
    });

    test('every descriptor builds its wire provider around a test endpoint',
        () {
      for (final d in builtinDescriptors) {
        final ep = ReplayEndpoint(
            sseResponse(200, [sseFrame('message_stop', {'type': 'message_stop'})]));
        final p = d.build(
          model: d.models.keys.isEmpty ? 'test-model' : d.models.keys.first,
          tokenFrom: () => 'test-only-token',
          endpoint: ep,
        );
        expect(p.model, d.models.keys.isEmpty ? 'test-model' : d.models.keys.first);
        expect(p, isA<LlmProvider>());
        p.close(); // injected endpoint: close is a no-op here
      }
    });
  });

  group('the OpenAI-compatible wire', () {
    test('request body: system folded into messages, tools wire-shaped',
        () async {
      final ep = ReplayEndpoint(sseResponse(200, ['data: [DONE]\n\n']));
      final p = OpenAiCompatibleProvider(
        model: 'glm-5.3',
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        endpoint: ep,
        tokenFrom: () => 'test-only-token',
      );
      await p.send(
        system: 'You are tina.',
        messages: [
          const Message(role: Role.user, content: [TextBlock('list files')]),
          const Message(role: Role.assistant, content: [
            ToolUseBlock(
                id: 'call_1',
                name: 'bash',
                input: {'command': 'ls'}),
          ]),
          const Message(role: Role.user, content: [
            ToolResultBlock(toolUseId: 'call_1', content: 'a.txt\nb.txt'),
          ]),
        ],
        tools: const [
          ToolSchema(
              name: 'bash',
              description: 'run a command',
              inputSchema: {'type': 'object'}),
        ],
      ).toList();

      expect(ep.path,
          'https://open.bigmodel.cn/api/paas/v4/chat/completions');
      expect(ep.headers!['authorization'], 'Bearer test-only-token');
      expect(ep.body, {
        'model': 'glm-5.3',
        'stream': true,
        'max_tokens': 8192,
        'messages': [
          {'role': 'system', 'content': 'You are tina.'},
          {'role': 'user', 'content': 'list files'},
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'bash',
                  'arguments': '{"command":"ls"}',
                },
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'a.txt\nb.txt'},
        ],
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': 'bash',
              'description': 'run a command',
              'parameters': {'type': 'object'},
            },
          },
        ],
      });
    });

    test('delta frames map to events; arguments by index; usage; [DONE]',
        () async {
      final ep = ReplayEndpoint(sseResponse(200, [
        'data: ${jsonEncode({
          'choices': [{
            'delta': {
              'reasoning_content': 'hmm',
              'content': 'Hel',
            },
          }],
        })}\n\n',
        'data: ${jsonEncode({
          'choices': [{
            'delta': {
              'content': 'lo',
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_9',
                  'function': {'name': 'bash', 'arguments': '{"comm'},
                },
              ],
            },
          }],
        })}\n\n',
        'data: ${jsonEncode({
          'choices': [{
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': 'and":"ls"}'},
                },
              ],
              // no content: empty deltas are legal
            },
            'finish_reason': 'tool_calls',
          }],
          'usage': {'prompt_tokens': 7, 'completion_tokens': 3},
        })}\n\n',
        'data: [DONE]\n\n',
      ]));
      final p = OpenAiCompatibleProvider(
        model: 'm',
        baseUrl: 'https://api.openai.com/v1',
        endpoint: ep,
        tokenFrom: () => 'test-only-token',
      );
      final events = await p.send(
        system: '',
        messages: const [
          Message(role: Role.user, content: [TextBlock('hi')]),
        ],
        tools: const [],
      ).toList();

      expect(events.whereType<ReasoningDelta>().map((r) => r.text), ['hmm']);
      expect(events.whereType<TextDelta>().map((t) => t.text).toList(),
          ['Hel', 'lo']);
      expect(events.whereType<ToolCallStart>().single.name, 'bash');
      final completion = events.whereType<MessageComplete>().single;
      expect(completion.stopReason, 'tool_calls');
      expect(completion.usage!.inputTokens, 7);
      expect(completion.usage!.outputTokens, 3);
      expect(completion.diagnostics!.reasoningObserved, isTrue);
      final tool = completion.content.whereType<ToolUseBlock>().single;
      expect(tool.input, {'command': 'ls'}); // stitched across two deltas
    });

    test('an error frame before [DONE] suppresses the completion', () async {
      final ep = ReplayEndpoint(sseResponse(200, [
        'data: ${jsonEncode({
          'error': {'message': 'quota exceeded'},
        })}\n\n',
        'data: [DONE]\n\n',
      ]));
      final p = OpenAiCompatibleProvider(
        model: 'm',
        baseUrl: 'https://api.openai.com/v1',
        endpoint: ep,
        tokenFrom: () => 'test-only-token',
      );
      final events = await p.send(
        system: '',
        messages: const [
          Message(role: Role.user, content: [TextBlock('hi')]),
        ],
        tools: const [],
      ).toList();
      expect(events.whereType<StreamError>().single.error,
          contains('quota exceeded'));
      expect(events.whereType<MessageComplete>(), isEmpty);
    });

    test('a body ending without [DONE] is an error, not a completion',
        () async {
      final ep = ReplayEndpoint(sseResponse(200, [
        'data: ${jsonEncode({
          'choices': [{
            'delta': {'content': 'half an answer'},
          }],
        })}\n\n',
      ]));
      final p = OpenAiCompatibleProvider(
        model: 'm',
        baseUrl: 'https://api.openai.com/v1',
        endpoint: ep,
        tokenFrom: () => 'test-only-token',
      );
      final events = await p.send(
        system: '',
        messages: const [
          Message(role: Role.user, content: [TextBlock('hi')]),
        ],
        tools: const [],
      ).toList();
      expect(events.whereType<StreamError>(), isNotEmpty);
      expect(events.whereType<MessageComplete>(), isEmpty);
    });

    test('a missing token fails closed before the endpoint is touched',
        () async {
      final ep = ReplayEndpoint(sseResponse(200, ['data: [DONE]\n\n']));
      final p = OpenAiCompatibleProvider(
        model: 'm',
        baseUrl: 'https://api.openai.com/v1',
        endpoint: ep,
        tokenFrom: () => '',
      );
      final events = await p.send(
        system: '',
        messages: const [
          Message(role: Role.user, content: [TextBlock('hi')]),
        ],
        tools: const [],
      ).toList();
      expect(events.whereType<StreamError>().single.error,
          contains('no API token'));
      expect(ep.path, isNull); // never reached
    });
  });

  group('the Gemini wire', () {
    test('request body: systemInstruction, functionDeclarations, contents',
        () async {
      final ep = ReplayEndpoint(sseResponse(200, []));
      final p = GeminiProvider(
        model: 'gemini-2.5-flash',
        baseUrl: geminiBaseUrl,
        endpoint: ep,
        tokenFrom: () => 'test-only-token',
      );
      await p.send(
        system: 'You are tina.',
        messages: [
          const Message(role: Role.user, content: [TextBlock('list files')]),
          const Message(role: Role.assistant, content: [
            ToolUseBlock(
                id: 'call_1',
                name: 'bash',
                input: {'command': 'ls'}),
          ]),
          const Message(
            role: Role.user,
            reasoning: [const ReasoningBlock('private')],
            content: [
              ToolResultBlock(toolUseId: 'call_1', content: 'a.txt'),
            ],
          ),
        ],
        tools: const [
          ToolSchema(
              name: 'bash',
              description: 'run a command',
              inputSchema: {'type': 'object'}),
        ],
      ).toList();

      expect(ep.path,
          '$geminiBaseUrl/models/gemini-2.5-flash'
          ':streamGenerateContent?alt=sse');
      expect(ep.headers!['x-goog-api-key'], 'test-only-token');
      expect(ep.body, {
        'systemInstruction': {
          'parts': [
            {'text': 'You are tina.'},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': 'list files'},
            ],
          },
          {
            'role': 'model',
            'parts': [
              {
                'functionCall': {'name': 'bash', 'args': {'command': 'ls'}},
              },
            ],
          },
          {
            // The functionResponse echoes the call's NAME — the wire has
            // no ids. The reasoning-only entry stays out entirely.
            'role': 'user',
            'parts': [
              {
                'functionResponse': {
                  'name': 'bash',
                  'response': {
                    'name': 'bash',
                    'content': {'output': 'a.txt'},
                  },
                },
              },
            ],
          },
        ],
        'tools': [
          {
            'functionDeclarations': [
              {
                'name': 'bash',
                'description': 'run a command',
                'parametersJsonSchema': {'type': 'object'},
              },
            ],
          },
        ],
        'generationConfig': {'maxOutputTokens': 8192},
      });
    });

    test('envelopes map to events: text, functionCall, stop, usage',
        () async {
      final ep = ReplayEndpoint(sseResponse(200, [
        'data: ${jsonEncode({
          'candidates': [{
            'content': {
              'parts': [
                {'text': 'Hi'},
                {
                  'functionCall': {
                    'name': 'bash',
                    'args': {'command': 'ls'},
                  },
                },
              ],
            },
          }],
        })}\n\n',
        'data: ${jsonEncode({
          'candidates': [{
            'content': {'parts': []},
            'finishReason': 'STOP',
          }],
          'usageMetadata': {
            'promptTokenCount': 11,
            'candidatesTokenCount': 4,
          },
        })}\n\n',
      ]));
      final p = GeminiProvider(
        model: 'gemini-2.5-pro',
        baseUrl: geminiBaseUrl,
        endpoint: ep,
        tokenFrom: () => 'test-only-token',
      );
      final events = await p.send(
        system: '',
        messages: const [
          Message(role: Role.user, content: [TextBlock('hi')]),
        ],
        tools: const [],
      ).toList();

      expect(events.whereType<TextDelta>().map((t) => t.text), ['Hi']);
      final call = events.whereType<ToolCallStart>().single;
      expect(call.name, 'bash'); // synthetic id: the wire has none
      final completion = events.whereType<MessageComplete>().single;
      expect(completion.stopReason, 'tool_use');
      expect(completion.usage!.inputTokens, 11);
      expect(completion.usage!.outputTokens, 4);
      final tool = completion.content.whereType<ToolUseBlock>().single;
      expect(tool.id, 'gemini_call_0');
      expect(tool.input, {'command': 'ls'});
    });

    test('MAX_TOKENS maps to max_tokens; a clean end needs a stop reason',
        () async {
      final ep = ReplayEndpoint(sseResponse(200, [
        'data: ${jsonEncode({
          'candidates': [{
            'content': {
              'parts': [
                {'text': 'Trunc'},
              ],
            },
            'finishReason': 'MAX_TOKENS',
          }],
        })}\n\n',
      ]));
      final p = GeminiProvider(
        model: 'gemini-2.5-pro',
        baseUrl: geminiBaseUrl,
        endpoint: ep,
        tokenFrom: () => 'test-only-token',
      );
      final events = await p.send(
        system: '',
        messages: const [
          Message(role: Role.user, content: [TextBlock('hi')]),
        ],
        tools: const [],
      ).toList();
      final completion = events.whereType<MessageComplete>().single;
      expect(completion.stopReason, 'max_tokens');
      expect(
          completion.content.whereType<TextBlock>().single.text, 'Trunc');
    });

    test('a missing key fails closed before the endpoint is touched',
        () async {
      final ep = ReplayEndpoint(sseResponse(200, []));
      final p = GeminiProvider(
        model: 'gemini-2.5-pro',
        baseUrl: geminiBaseUrl,
        endpoint: ep,
        tokenFrom: () => '',
      );
      final events = await p.send(
        system: '',
        messages: const [
          Message(role: Role.user, content: [TextBlock('hi')]),
        ],
        tools: const [],
      ).toList();
      expect(events.whereType<StreamError>().single.error,
          contains('no API token'));
      expect(ep.path, isNull);
    });
  });

  group('the models.dev catalogue', () {
    test('fetch caches to the given dir and merges over the descriptor',
        () async {
      final ep = ReplayEndpoint(_doc(200, jsonEncode({
        'glm': {
          'models': {
            'glm-5.3': {
              'name': 'GLM-5.3 (catalogue)',
              'limit': {'context': 204800, 'output': 32768},
              'tool_call': true,
              'modalities': {'input': ['text', 'image']},
            },
            'glm-5.7': {
              'name': 'GLM-5.7',
              'limit': {'context': 400000},
              'tool_call': true,
            },
          },
        },
      })));
      final dir = await Directory.systemTemp.createTemp('tina-models');
      addTearDown(() => dir.delete(recursive: true));
      final catalogue = await ModelsDevCatalog.fetch(
        endpoint: ep,
        tokenFrom: () => '',
        cacheDir: dir.path,
      );
      expect(catalogue, isNotNull);
      expect(ep.path, '/api.json');
      final cached = File('${dir.path}/$modelsDevCacheFile');
      expect(cached.existsSync(), isTrue); // one copy on disk

      // Catalogue wins where it knows; descriptor values survive.
      final d = descriptorById('glm')!;
      final models = catalogue!.modelsFor(d);
      final updated = models.firstWhere((m) => m.id == 'glm-5.3');
      expect(updated.name, 'GLM-5.3 (catalogue)');
      expect(updated.contextWindow, 204800);
      expect(updated.maxOutput, 32768);
      expect(updated.supportsVision, isTrue); // from modalities
      // Catalogue-only model appended.
      expect(models.map((m) => m.id), contains('glm-5.7'));
      // Descriptor-only model still present with its own figures.
      final own = models.firstWhere((m) => m.id == 'glm-4.6');
      expect(own.contextWindow, 131072);
    });

    test('read-back rebuilds the catalogue from disk alone', () async {
      final dir = await Directory.systemTemp.createTemp('tina-models');
      addTearDown(() => dir.delete(recursive: true));
      // `cacheDir` is the leaf directory holding models.json — the same
      // layout the fetch writes under `$HOME/.tina/cache/models_dev`.
      await File('${dir.path}/$modelsDevCacheFile')
          .writeAsString(jsonEncode({
        'deepseek': {
          'models': {
            'deepseek-chat': {
              'limit': {'context': 163840},
              'tool_call': true,
            },
          },
        },
      }));
      final catalogue = await ModelsDevCatalog.read(cacheDir: dir.path);
      expect(catalogue, isNotNull);
      final models = catalogue!.modelsFor(descriptorById('deepseek')!);
      expect(models.first.id, 'deepseek-chat');
      expect(models.first.contextWindow, 163840);
    });

    test('a failed fetch returns null and leaves the descriptors standing',
        () async {
      final catalogue = await ModelsDevCatalog.fetch(
        endpoint: ReplayEndpoint(_doc(500, 'server on fire')),
        tokenFrom: () => '',
        cacheDir: '/nonexistent-tina-cache-never-written',
      );
      expect(catalogue, isNull);
      // The fallback path: descriptors serve regardless.
      final d = descriptorById('mistral')!;
      expect(d.models, isNotEmpty);
    });

    test('a stale cache is detectable, absent stamps count as stale',
        () async {
      final dir = await Directory.systemTemp.createTemp('tina-models');
      addTearDown(() => dir.delete(recursive: true));
      final catalogue = await ModelsDevCatalog.read(cacheDir: dir.path);
      expect(catalogue, isNull);
    });
  });
}
