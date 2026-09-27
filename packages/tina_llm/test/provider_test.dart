// The four required provider behaviors, headless: recorded bytes over an
// injected endpoint, no network, no credentials anywhere.
//
// Run: dart test
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';

/// A canned response: status, headers, body chunks.
HttpResponse _response(int status, List<String> chunks,
        {Map<String, String> headers = const {}}) =>
    HttpResponse(
      statusCode: status,
      headers: headers,
      body: Stream.fromIterable([
        for (final c in chunks) utf8.encode(c),
      ]),
    );

/// An endpoint that records the request and replays [response].
final class _ReplayEndpoint implements HttpEndpoint {
  _ReplayEndpoint(this.response);

  final HttpResponse response;
  String? path;
  Map<String, String>? headers;
  Map<String, dynamic>? body;

  @override
  Future<HttpResponse> post(
    String path, {
    required Map<String, String> headers,
    required List<int> body,
  }) async {
    this.path = path;
    this.headers = headers;
    this.body =
        jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
    return response;
  }

  @override
  Future<HttpResponse> get(
    String path, {
    Map<String, String> headers = const {},
  }) async {
    this.path = path;
    this.headers = headers;
    return response;
  }
}

AnthropicProvider _provider(HttpEndpoint endpoint) => AnthropicProvider(
      model: 'test-model',
      endpoint: endpoint,
      // No token anywhere: the test value lives only in this closure.
      tokenFrom: () => 'test-only-token',
    );

/// Run one send and collect the events.
Future<List<StreamEvent>> _collect(Stream<StreamEvent> stream) async =>
    stream.toList();

/// SSE frames as the wire sends them: `event:` line, `data:` line, blank.
String _frame(String type, Map<String, dynamic> data) =>
    'event: $type\ndata: ${jsonEncode(data)}\n\n';

void main() {
  group('the request body', () {
    test('plain text turn: exact JSON', () async {
      final ep = _ReplayEndpoint(_response(200, [
        _frame('message_stop', {'type': 'message_stop'}),
      ]));
      final p = _provider(ep);

      await _collect(p.send(
        system: 'You are tina.',
        messages: [
          const Message(role: Role.user, content: [TextBlock('hello')]),
        ],
        tools: const [],
      ));

      expect(ep.body, {
        'model': 'test-model',
        'max_tokens': 8192,
        'stream': true,
        'system': 'You are tina.',
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'hello'},
            ],
          },
        ],
      });
      expect(ep.path, '/v1/messages');
      expect(ep.headers!['content-type'], 'application/json');
      // The auth header is present but its value never appears in a
      // failure message — see the missing-token test below. An injected
      // token rides `authorization` (bearer): the shape the gateway's
      // AUTH_TOKEN vars use; the env-sourced API_KEY would ride
      // `x-api-key` instead.
      expect(ep.headers!['authorization'], 'Bearer test-only-token');
    });

    test('a tool call in the transcript: exact JSON', () async {
      final ep = _ReplayEndpoint(_response(200, [
        _frame('message_stop', {'type': 'message_stop'}),
      ]));
      final p = _provider(ep);

      await _collect(p.send(
        system: '',
        messages: [
          const Message(role: Role.assistant, content: [
            ToolUseBlock(id: 'toolu_1', name: 'write', input: {
              'filePath': 'a.txt',
              'content': 'x',
            }),
          ]),
          const Message(role: Role.user, content: [
            ToolResultBlock(toolUseId: 'toolu_1', content: 'created a.txt'),
          ]),
        ],
        tools: [
          const ToolSchema(
            name: 'write',
            description: 'Write a file.',
            inputSchema: {
              'type': 'object',
              'properties': {'filePath': {'type': 'string'}},
              'required': ['filePath'],
            },
          ),
        ],
      ));

      expect(ep.body, {
        'model': 'test-model',
        'max_tokens': 8192,
        'stream': true,
        'messages': [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'write',
                'input': {'filePath': 'a.txt', 'content': 'x'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'toolu_1',
                'content': 'created a.txt',
              },
            ],
          },
        ],
        'tools': [
          {
            'name': 'write',
            'description': 'Write a file.',
            'input_schema': {
              'type': 'object',
              'properties': {
                'filePath': {'type': 'string'},
              },
              'required': ['filePath'],
            },
          },
        ],
      });
    });

    test('a reasoning block goes back with its signature intact',
        () async {
      final ep = _ReplayEndpoint(_response(200, [
        _frame('message_stop', {'type': 'message_stop'}),
      ]));
      final p = _provider(ep);

      await _collect(p.send(
        system: '',
        messages: [
          const Message(
            role: Role.assistant,
            content: [TextBlock('the answer')],
            reasoning: [
              ReasoningBlock(
                'private reasoning',
                signature: 'sig-abc123',
              ),
            ],
          ),
        ],
        tools: const [],
      ));

      final content = (ep.body!['messages'] as List).first['content'];
      expect(content[0], {
        'type': 'thinking',
        'thinking': 'private reasoning',
        'signature': 'sig-abc123',
      });
      expect(content[1], {
        'type': 'text',
        'text': 'the answer',
      });
    });
  });

  group('recorded frames to events', () {
    test('text deltas, tool call, reasoning with signature, usage, error',
        () async {
      final ep = _ReplayEndpoint(_response(200, [
        _frame('message_start', {
          'type': 'message_start',
          'message': {'role': 'assistant'},
        }),
        _frame('ping', {'type': 'ping'}),
        _frame('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'thinking'},
        }),
        _frame('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': 'hmm'},
        }),
        // Wrong key on purpose? No — the wire uses `thinking` for the
        // delta and `text` for text. Verify both mappings.
        _frame('content_block_delta', {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'signature_delta', 'signature': 'sig-9'},
        }),
        _frame('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        _frame('content_block_start', {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'text'},
        }),
        _frame('content_block_delta', {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'text_delta', 'text': 'the answer'},
        }),
        _frame('content_block_start', {
          'type': 'content_block_start',
          'index': 2,
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_2',
            'name': 'bash',
          },
        }),
        _frame('content_block_delta', {
          'type': 'content_block_delta',
          'index': 2,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': '{"command":"echo hi"}',
          },
        }),
        _frame('message_delta', {
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
          'usage': {
            'input_tokens': 12,
            'output_tokens': 34,
            'cache_creation_input_tokens': 5,
            'cache_read_input_tokens': 6,
          },
        }),
        _frame('message_stop', {'type': 'message_stop'}),
      ]));
      final p = _provider(ep);

      final events = await _collect(p.send(
          system: '', messages: const [], tools: const []));

      // Streaming events, in wire order: reasoning opens (an empty
      // ReasoningDelta marked startsBlock), deltas flow, the signature
      // ends the thinking block, text deltas, tool start.
      final reasoning = events.whereType<ReasoningDelta>().toList();
      expect(reasoning.map((r) => r.text), ['', 'hmm']);
      expect(reasoning.first.startsBlock, isTrue);
      expect(reasoning.last.startsBlock, isFalse);
      final sig = events.whereType<ReasoningEnd>().single;
      expect(sig.signature, 'sig-9');
      expect(events.whereType<TextDelta>().map((t) => t.text).toList(),
          ['the answer']);
      final tool = events.whereType<ToolCallStart>().single;
      expect(tool.id, 'toolu_2');
      expect(tool.name, 'bash');

      // The completion carries the blocks, the stop reason, and usage.
      final completion = events.whereType<MessageComplete>().single;
      expect(completion.stopReason, 'tool_use');
      final usage = completion.usage!;
      expect(usage.inputTokens, 12);
      expect(usage.outputTokens, 34);
      expect(usage.cacheCreationInputTokens, 5);
      expect(usage.cacheReadInputTokens, 6);
      expect(completion.diagnostics!.reasoningObserved, isTrue);
      final toolBlock =
          completion.content.whereType<ToolUseBlock>().single;
      expect(toolBlock.input, {'command': 'echo hi'});
      expect(
          completion.content.whereType<TextBlock>().single.text,
          'the answer');
    });

    test('an error frame becomes a StreamError in the stream', () async {
      final ep = _ReplayEndpoint(_response(200, [
        _frame('error', {
          'type': 'error',
          'error': {'type': 'overloaded_error', 'message': 'overloaded'},
        }),
      ]));
      final p = _provider(ep);

      final events = await _collect(
          p.send(system: '', messages: const [], tools: const []));

      final err = events.whereType<StreamError>().single;
      expect(err.error, 'overloaded');
      expect(err.providerCode, 'overloaded_error');
      // And nothing else: no completion is fabricated after an error.
      expect(events.whereType<MessageComplete>(), isEmpty);
    });

    test('a malformed frame is surfaced, not swallowed', () async {
      final ep = _ReplayEndpoint(_response(200, [
        'data: {not json}\n\n',
        _frame('message_stop', {'type': 'message_stop'}),
      ]));
      final p = _provider(ep);

      final events = await _collect(
          p.send(system: '', messages: const [], tools: const []));

      expect(
          events.whereType<StreamError>().single.error,
          contains('bad frame'));
    });
  });

  group('a stalled stream', () {
    test('becomes a stream error instead of waiting forever', () async {
      // A body that emits one chunk, then goes silent — forever.
      final controller = StreamController<List<int>>();
      final ep = _ReplayEndpoint(
          HttpResponse(statusCode: 200, body: controller.stream));
      final p = AnthropicProvider(
        model: 'test-model',
        endpoint: ep,
        stallTimeout: const Duration(milliseconds: 60),
        tokenFrom: () => 'test-only-token',
      );

      final collected = _collect(p.send(
          system: '', messages: const [], tools: const []));
      controller.add(utf8.encode(_frame('ping', {'type': 'ping'})));

      final events = await collected;
      final err = events.whereType<StreamError>().single;
      expect(err.error, contains('stalled'));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('credentials', () {
    test('a missing token gives a clear stream error, not a crash',
        () async {
      final ep = _ReplayEndpoint(_response(200, []));
      // The factory never consults the environment in this test: the
      // token source is an explicit null, exactly what a host sees when
      // neither environment variable is set.
      final p = AnthropicProvider(
        model: 'test-model',
        endpoint: ep,
        tokenFrom: () => null,
      );

      final events = await _collect(
          p.send(system: '', messages: const [], tools: const []));

      final err = events.whereType<StreamError>().single;
      expect(err.error, contains('no API token'));
      expect(err.error, contains('TINA_LLM_TOKEN'));
      // Nothing reached the endpoint: the request was never made.
      expect(ep.path, isNull);
    });

    test('a non-200 body surfaces the server message, not the token',
        () async {
      final ep = _ReplayEndpoint(_response(401, [
        jsonEncode({
          'type': 'error',
          'error': {'type': 'authentication_error',
              'message': 'invalid x-api-key'},
        }),
      ]));
      final p = _provider(ep);

      final events = await _collect(
          p.send(system: '', messages: const [], tools: const []));

      final err = events.whereType<StreamError>().single;
      expect(err.error, contains('HTTP 401'));
      expect(err.error, contains('invalid x-api-key'));
      expect(err.statusCode, 401);
      expect(err.requiresUserAction, isTrue);
    });
  });
}
