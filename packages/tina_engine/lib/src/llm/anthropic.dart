import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../tools/tool.dart';
import 'http.dart';
import 'http_log.dart';
import 'message.dart';
import 'provider.dart';
import 'sse.dart';

final _log = Logger('tina.llm');

class AnthropicProvider extends LlmProvider {
  final String apiKey;
  final bool useBearerAuth;
  final int maxTokens;
  final String baseUrl;
  final Duration streamIdleTimeout;
  final Duration requestTimeout;
  final http.Client _client;

  AnthropicProvider({
    required this.apiKey,
    required String model,
    this.useBearerAuth = false,
    this.maxTokens = 8192,
    this.baseUrl = 'https://api.anthropic.com',
    this.streamIdleTimeout = defaultStreamIdleTimeout,
    this.requestTimeout = defaultRequestTimeout,
    http.Client? client,
  })  : _client = client ?? http.Client(),
        super(model);

  @override
  void close() => _client.close();

  http.Request _buildRequest(String body) {
    final r = http.Request('POST', Uri.parse('$baseUrl/v1/messages'));
    r.headers.addAll({
      'content-type': 'application/json',
      'anthropic-version': '2023-06-01',
      if (useBearerAuth)
        'authorization': 'Bearer $apiKey'
      else
        'x-api-key': apiKey,
    });
    r.body = body;
    return r;
  }

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    // Three cache_control markers:
    //   1. end of system        — caches the system prompt
    //   2. end of tools         — caches system + tools
    //   3. end of history[-2]   — caches everything except the just-added
    //                             user/tool_result message, so the next
    //                             turn reads up through this turn for free
    // Anthropic allows up to 4 markers; we leave one in reserve.
    final encodedTools = <Map<String, dynamic>>[
      for (var i = 0; i < tools.length; i++)
        _encodeTool(tools[i], cache: i == tools.length - 1),
    ];
    final cacheMessageAt = messages.length - 2;
    final encodedMessages = <Map<String, dynamic>>[
      for (var i = 0; i < messages.length; i++)
        _encodeMessage(messages[i], cacheLastBlock: i == cacheMessageAt),
    ];

    final body = jsonEncode({
      'model': model,
      'max_tokens': maxTokens,
      'system': [
        {
          'type': 'text',
          'text': system,
          'cache_control': const {'type': 'ephemeral'},
        }
      ],
      'messages': encodedMessages,
      if (tools.isNotEmpty) 'tools': encodedTools,
      'stream': true,
    });
    HttpLog.log(Uri.parse('$baseUrl/v1/messages'), body);

    final http.StreamedResponse resp;
    try {
      resp = await sendOnce(_client, () => _buildRequest(body),
          requestTimeout: requestTimeout);
    } catch (e) {
      yield StreamError(humanizeException(e), transient: isTransientException(e));
      return;
    }
    if (resp.statusCode != 200) {
      final text = await resp.stream.bytesToString();
      yield StreamError(humanizeHttpError('Anthropic', resp.statusCode, text),
          statusCode: resp.statusCode,
          retryAfter: parseRetryAfter(resp.headers['retry-after']));
      return;
    }

    final blocks = <int, _BlockBuilder>{};
    var stopReason = 'end_turn';
    var inputTokens = 0;
    var outputTokens = 0;
    var cacheCreationInputTokens = 0;
    var cacheReadInputTokens = 0;

    // Wrap the SSE consumption: humanize any error (network drop, stall,
    // bad framing) and surface it as StreamError rather than letting the
    // raw exception bubble up to the agent.
    // WHY (#23 / #24): stream-idle must name its knob — same anonymous
    // 'Request timed out' made operators raise --request-timeout instead,
    // which did nothing. Naming the flag lets the operator fix the right knob.
    final rawEvents = resp.stream.timeout(
      streamIdleTimeout,
      onTimeout: (sink) {
        sink.addError(TimeoutException(
          'no stream events for ${streamIdleTimeout.inSeconds}s — '
          'raise with --stream-idle-timeout',
          streamIdleTimeout,
        ));
        sink.close();
      },
    );
    final events = parseSse(rawEvents);
    Stream<Map<String, dynamic>> decoded() async* {
      await for (final payload in events) {
        try {
          yield jsonDecode(payload) as Map<String, dynamic>;
        } catch (e) {
          // SSE keep-alive / non-JSON line — skip, but record for debugging.
          _log.fine('skipped non-JSON SSE line', e);
        }
      }
    }

    try {
      await for (final evt in decoded()) {
        switch (evt['type']) {
          case 'message_start':
            final msg = evt['message'] as Map<String, dynamic>?;
            final usage = msg?['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              inputTokens = (usage['input_tokens'] as int?) ?? 0;
              outputTokens = (usage['output_tokens'] as int?) ?? 0;
              cacheCreationInputTokens =
                  (usage['cache_creation_input_tokens'] as int?) ?? 0;
              cacheReadInputTokens =
                  (usage['cache_read_input_tokens'] as int?) ?? 0;
            }
            break;

          case 'content_block_start':
            final idx = evt['index'] as int;
            final cb = evt['content_block'] as Map<String, dynamic>;
            switch (cb['type']) {
              case 'text':
                blocks[idx] = _TextBuilder();
                break;
              case 'tool_use':
                final b = _ToolUseBuilder(
                  id: cb['id'] as String,
                  name: cb['name'] as String,
                );
                blocks[idx] = b;
                yield ToolCallStart(id: b.id, name: b.name);
                break;
              default:
                blocks[idx] = _NullBuilder();
            }
            break;

          case 'content_block_delta':
            final idx = evt['index'] as int;
            final delta = evt['delta'] as Map<String, dynamic>;
            final b = blocks[idx];
            switch (delta['type']) {
              case 'text_delta':
                if (b is _TextBuilder) {
                  final t = delta['text'] as String;
                  b.text.write(t);
                  yield TextDelta(t);
                }
                break;
              case 'input_json_delta':
                if (b is _ToolUseBuilder) {
                  b.jsonFragments.write(delta['partial_json'] as String);
                }
                break;
            }
            break;

          case 'message_delta':
            final delta = evt['delta'] as Map<String, dynamic>?;
            final sr = delta?['stop_reason'];
            if (sr is String) stopReason = sr;
            final usage = evt['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              final out = usage['output_tokens'];
              if (out is int) outputTokens = out;
            }
            break;

          case 'message_stop':
            final indices = blocks.keys.toList()..sort();
            final assembled = <ContentBlock>[];
            for (final i in indices) {
              final cb = blocks[i]!.build();
              if (cb != null) assembled.add(cb);
            }
            yield MessageComplete(
              content: assembled,
              stopReason: stopReason,
              usage: TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens,
                cacheReadInputTokens: cacheReadInputTokens,
              ),
            );
            return;

          case 'error':
            final err = evt['error'];
            if (err is Map && err['message'] is String) {
              final type =
                  err['type'] is String ? '${err['type']}: ' : '';
              yield StreamError('Anthropic: $type${err['message']}');
            } else {
              yield StreamError('Anthropic: $err');
            }
            return;
        }
      }
    } catch (e) {
      yield StreamError(humanizeException(e));
    }
  }

  Map<String, dynamic> _encodeMessage(Message m, {bool cacheLastBlock = false}) {
    final role = m.role == Role.user ? 'user' : 'assistant';
    final content = m.content.map<Map<String, dynamic>>((b) {
      if (b is TextBlock) return {'type': 'text', 'text': b.text};
      if (b is ToolUseBlock) {
        return {
          'type': 'tool_use',
          'id': b.id,
          'name': b.name,
          'input': b.input,
        };
      }
      if (b is ToolResultBlock) {
        return {
          'type': 'tool_result',
          'tool_use_id': b.toolUseId,
          'content': b.content,
          if (b.isError) 'is_error': true,
        };
      }
      throw StateError('unknown content block: $b');
    }).toList();
    if (cacheLastBlock && content.isNotEmpty) {
      content.last['cache_control'] = const {'type': 'ephemeral'};
    }
    return {'role': role, 'content': content};
  }

  Map<String, dynamic> _encodeTool(ToolSchema t, {bool cache = false}) => {
        'name': t.name,
        'description': t.description,
        'input_schema': t.inputSchema,
        if (cache) 'cache_control': const {'type': 'ephemeral'},
      };
}

sealed class _BlockBuilder {
  ContentBlock? build();
}

class _TextBuilder extends _BlockBuilder {
  final StringBuffer text = StringBuffer();
  @override
  ContentBlock build() => TextBlock(text.toString());
}

class _ToolUseBuilder extends _BlockBuilder {
  final String id;
  final String name;
  final StringBuffer jsonFragments = StringBuffer();
  _ToolUseBuilder({required this.id, required this.name});

  @override
  ContentBlock build() {
    final s = jsonFragments.toString();
    if (s.isEmpty) return ToolUseBlock(id: id, name: name, input: const {});
    try {
      return ToolUseBlock(
          id: id, name: name, input: jsonDecode(s) as Map<String, dynamic>);
    } on FormatException catch (e) {
      // Same recovery as the OpenAI adapter (tin-p2sq): a malformed
      // argument stream becomes a per-call parse error the agent feeds back
      // to the model, not a turn abort.
      return ToolUseBlock(
        id: id,
        name: name,
        input: const {},
        argumentsParseError: e.message,
      );
    }
  }
}

class _NullBuilder extends _BlockBuilder {
  @override
  ContentBlock? build() => null;
}
