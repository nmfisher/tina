import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_http.dart';

void main() {
  group('AnthropicProvider prompt caching', () {
    test('marks system, last tool, and second-to-last message', () async {
      final captured = CapturedRequest();
      final provider = AnthropicProvider(
        apiKey: 'sk-test',
        model: 'claude-test',
        client: captured.client,
      );
      final tools = const [
        ToolSchema(name: 'a', description: 'a', inputSchema: {'type': 'object'}),
        ToolSchema(name: 'b', description: 'b', inputSchema: {'type': 'object'}),
      ];
      final history = const [
        Message(role: Role.user, content: [TextBlock('first user turn')]),
        Message(role: Role.assistant, content: [TextBlock('first reply')]),
        Message(role: Role.user, content: [TextBlock('second user turn')]),
      ];

      // Drain the stream so the encoder runs.
      await provider
          .send(system: 'you are tina', messages: history, tools: tools)
          .toList();

      final body = jsonDecode(captured.body!) as Map<String, dynamic>;

      // System: array form with cache_control on the single text block.
      final system = body['system'] as List;
      expect(system, hasLength(1));
      final systemBlock = system.first as Map<String, dynamic>;
      expect(systemBlock['text'], 'you are tina');
      expect(systemBlock['cache_control'], {'type': 'ephemeral'});

      // Tools: cache_control on the last entry only.
      final encodedTools = body['tools'] as List;
      expect(encodedTools, hasLength(2));
      expect((encodedTools[0] as Map).containsKey('cache_control'), isFalse);
      expect(
          (encodedTools[1] as Map)['cache_control'], {'type': 'ephemeral'});

      // Messages: cache_control on the last content block of history[len-2],
      // which is the assistant reply at index 1. The last message (the new
      // user turn) is NOT cached so it stays in the uncached suffix.
      final encodedMessages = body['messages'] as List;
      final replyContent = (encodedMessages[1] as Map)['content'] as List;
      expect(
          (replyContent.last as Map)['cache_control'], {'type': 'ephemeral'});
      final lastContent = (encodedMessages[2] as Map)['content'] as List;
      expect((lastContent.last as Map).containsKey('cache_control'), isFalse);
    });

    test('skips message breakpoint when history has fewer than 2 messages',
        () async {
      final captured = CapturedRequest();
      final provider = AnthropicProvider(
        apiKey: 'sk-test',
        model: 'claude-test',
        client: captured.client,
      );
      await provider.send(
        system: 'sys',
        messages: const [
          Message(role: Role.user, content: [TextBlock('hi')]),
        ],
        tools: const [],
      ).toList();

      final body = jsonDecode(captured.body!) as Map<String, dynamic>;
      final messages = body['messages'] as List;
      final content = (messages.single as Map)['content'] as List;
      expect((content.single as Map).containsKey('cache_control'), isFalse);
    });

    test('parses cache_creation/read tokens from message_start usage',
        () async {
      // SSE script: message_start with usage including cache numbers, then
      // an immediate message_stop. Provider should surface them on
      // MessageComplete.
      final events = [
        'event: message_start',
        'data: ${jsonEncode({
              'type': 'message_start',
              'message': {
                'usage': {
                  'input_tokens': 12,
                  'output_tokens': 3,
                  'cache_creation_input_tokens': 100,
                  'cache_read_input_tokens': 500,
                },
              },
            })}',
        '',
        'event: message_stop',
        'data: ${jsonEncode({'type': 'message_stop'})}',
        '',
      ].join('\n');

      final provider = AnthropicProvider(
        apiKey: 'sk-test',
        model: 'claude-test',
        client: ScriptedSseClient(events),
      );
      final completes = await provider
          .send(system: 'sys', messages: const [], tools: const [])
          .where((e) => e is MessageComplete)
          .cast<MessageComplete>()
          .toList();

      expect(completes, hasLength(1));
      final usage = completes.single.usage!;
      expect(usage.inputTokens, 12);
      expect(usage.outputTokens, 3);
      expect(usage.cacheCreationInputTokens, 100);
      expect(usage.cacheReadInputTokens, 500);
    });
  });

  group('TokenUsage', () {
    test('sums cache fields under +', () {
      const a = TokenUsage(
        inputTokens: 1,
        outputTokens: 2,
        cacheCreationInputTokens: 10,
        cacheReadInputTokens: 20,
      );
      const b = TokenUsage(
        inputTokens: 3,
        outputTokens: 4,
        cacheCreationInputTokens: 30,
        cacheReadInputTokens: 40,
      );
      final c = a + b;
      expect(c.inputTokens, 4);
      expect(c.outputTokens, 6);
      expect(c.cacheCreationInputTokens, 40);
      expect(c.cacheReadInputTokens, 60);
    });

    test('isEmpty considers cache fields', () {
      const u = TokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadInputTokens: 5,
      );
      expect(u.isEmpty, isFalse);
    });
  });

  group('error handling', () {
    test('non-200 yields a StreamError with the humanized body', () async {
      final provider = AnthropicProvider(
        apiKey: 'sk-test',
        model: 'claude-test',
        client: ScriptedSseClient(
          jsonEncode({'error': {'message': 'bad request'}}),
          status: 400,
        ),
      );
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();
      expect(events.whereType<StreamError>().single.error,
          'Anthropic 400: bad request');
    });

    test('an error SSE event yields a typed StreamError', () async {
      final sse = 'data: ${jsonEncode({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          })}\n\n';
      final provider = AnthropicProvider(
        apiKey: 'sk-test',
        model: 'claude-test',
        client: ScriptedSseClient(sse),
      );
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();
      expect(events.whereType<StreamError>().single.error,
          'Anthropic: overloaded_error: Overloaded');
    });

    // #24: a stream that goes silent mid-response must surface an error that
    // names --stream-idle-timeout (previously the same anonymous 'Request
    // timed out' string as the request timeout, so operators raised the
    // wrong knob).
    test('a stream that goes silent names --stream-idle-timeout', () async {
      final provider = AnthropicProvider(
        apiKey: 'sk-test',
        model: 'claude-test',
        streamIdleTimeout: const Duration(milliseconds: 100),
        client: SilentSseClient(),
      );
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();
      final err = events.whereType<StreamError>().single;
      expect(err.error, contains('no stream events for'));
      expect(err.error, contains('--stream-idle-timeout'));
    });
  });
}
