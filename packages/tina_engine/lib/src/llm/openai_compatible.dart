import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../tools/tool.dart';
import 'http.dart';
import 'message.dart';
import 'provider.dart';
import 'registry.dart';
import 'sse.dart';

final _log = Logger('tina.llm');

/// A generic [LlmProvider] that speaks OpenAI's `/v1/chat/completions`
/// protocol. Most hosted and local services (OpenAI, DeepSeek, GLM, Groq, xAI,
/// Mistral, Qwen, OpenRouter, Ollama, vLLM, LM Studio) expose this interface,
/// so each is just a [ProviderDescriptor] whose builder constructs one of
/// these — no per-provider wire code.
class OpenAiCompatibleAdapter extends LlmProvider {
  final String apiKey;
  final int maxTokens;
  final String baseUrl;
  final Duration streamIdleTimeout;
  final Duration requestTimeout;

  /// Display name used in error messages (e.g. "OpenAI", "DeepSeek").
  final String label;

  /// Extra top-level fields merged into the request body (last-wins), sourced
  /// from [ModelInfo.extraBody]. Lets a model inject provider-specific params
  /// — e.g. NIM's `{"chat_template_kwargs": {"enable_thinking": true}}` — with
  /// no per-provider wire code. Empty for models that need none.
  final Map<String, dynamic> extraBody;
  final http.Client _client;

  OpenAiCompatibleAdapter({
    required this.apiKey,
    required String model,
    this.maxTokens = 8192,
    this.baseUrl = 'https://api.openai.com',
    this.streamIdleTimeout = defaultStreamIdleTimeout,
    this.requestTimeout = defaultRequestTimeout,
    this.label = 'OpenAI',
    this.extraBody = const {},
    http.Client? client,
  })  : _client = client ?? http.Client(),
        super(model);

  @override
  void close() => _client.close();

  /// Builds the `/chat/completions` URL from a base, tolerating either form
  /// providers publish: a bare host (`https://api.openai.com`) or a fully
  /// versioned path (`https://api.groq.com/openai/v1`, GLM's `/api/paas/v4`).
  ///
  /// If the path already ends in a version segment `/v<digits>`, only
  /// `/chat/completions` is appended; otherwise `/v1/chat/completions` is
  /// appended (the OpenAI/DeepSeek default). Without this, a base URL that
  /// already contains `/v1` (or GLM's `/v4`) would double up to
  /// `/v1/v1/chat/completions`.
  static String chatEndpoint(String baseUrl) {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (RegExp(r'/v\d+$').hasMatch(b)) return '$b/chat/completions';
    return '$b/v1/chat/completions';
  }

  http.Request _buildRequest(String body) {
    final r = http.Request('POST', Uri.parse(chatEndpoint(baseUrl)));
    final headers = <String, String>{'content-type': 'application/json'};
    // Local/no-auth servers (Ollama) ignore the header; sending an empty
    // Bearer can be rejected by some proxies, so omit it when there's no key.
    if (apiKey.isNotEmpty) headers['authorization'] = 'Bearer $apiKey';
    r.headers.addAll(headers);
    r.body = body;
    return r;
  }

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    final bodyMap = <String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      'messages': _encodeMessages(system, messages),
      if (tools.isNotEmpty) 'tools': tools.map(_encodeTool).toList(),
      'stream': true,
      'stream_options': {'include_usage': true},
    };
    // Provider-specific extras win (merged last), so a model can override even
    // a default like `stream_options` if its endpoint requires it.
    if (extraBody.isNotEmpty) bodyMap.addAll(extraBody);
    final body = jsonEncode(bodyMap);

    final http.StreamedResponse resp;
    try {
      resp = await sendWithRetry(_client, () => _buildRequest(body),
          requestTimeout: requestTimeout);
    } catch (e) {
      yield StreamError(humanizeException(e));
      return;
    }
    if (resp.statusCode != 200) {
      final text = await resp.stream.bytesToString();
      yield StreamError(humanizeHttpError(label, resp.statusCode, text));
      return;
    }

    final textBuf = StringBuffer();
    final thinkingBuf = StringBuffer();
    var _inThinking = false;
    final toolCalls = <int, _PartialCall>{};
    var finishReason = 'stop';
    var promptTokens = 0;
    var completionTokens = 0;

    final events = parseSse(resp.stream).timeout(streamIdleTimeout);
    try {
      await for (final payload in events) {
        final Map<String, dynamic> evt;
        try {
          evt = jsonDecode(payload) as Map<String, dynamic>;
        } catch (e) {
          _log.fine('skipped non-JSON SSE line', e);
          continue;
        }
        final usage = evt['usage'];
        if (usage is Map) {
          promptTokens = (usage['prompt_tokens'] as int?) ?? promptTokens;
          completionTokens =
              (usage['completion_tokens'] as int?) ?? completionTokens;
        }
        final choices = evt['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices.first as Map<String, dynamic>;

        final delta = choice['delta'] as Map<String, dynamic>?;
        if (delta != null) {
          final c = delta['content'];
          if (c is String && c.isNotEmpty) {
            // Filter thinking-block tokens that some models embed in content.
            // DeepSeek V4 / Hy3 emit <|channel>thought … <channel|> inline.
            var filtered = c;
            if (_inThinking) {
              final end = filtered.indexOf('<channel|>');
              if (end >= 0) {
                _inThinking = false;
                filtered = filtered.substring(end + '<channel|>'.length);
              } else {
                thinkingBuf.write(filtered);
                continue; // swallow — still inside thinking block
              }
            }
            // Check for a new thinking block (may span the remainder).
            var start = filtered.indexOf('<|channel>');
            while (start >= 0) {
              textBuf.write(filtered.substring(0, start));
              final rest = filtered.substring(start + '<|channel>'.length);
              final end = rest.indexOf('<channel|>');
              if (end >= 0) {
                thinkingBuf.write(rest.substring(0, end));
                filtered = rest.substring(end + '<channel|>'.length);
              } else {
                thinkingBuf.write(rest);
                _inThinking = true;
                filtered = '';
                break;
              }
              start = filtered.indexOf('<|channel>');
            }
            if (!_inThinking && filtered.isNotEmpty) {
              textBuf.write(filtered);
              yield TextDelta(filtered);
            }
          }
          // Some reasoning models (DeepSeek-reasoner, GLM thinking) stream a
          // separate `reasoning_content`. We deliberately drop it rather than
          // splice it into the response; surfacing it is a future enhancement.
          final tc = delta['tool_calls'] as List?;
          if (tc != null) {
            for (final t in tc) {
              final tm = t as Map<String, dynamic>;
              final idx = (tm['index'] as int?) ?? 0;
              final partial = toolCalls.putIfAbsent(idx, _PartialCall.new);
              final id = tm['id'];
              if (id is String) partial.id ??= id;
              final fn = tm['function'] as Map<String, dynamic>?;
              if (fn != null) {
                final n = fn['name'];
                if (n is String && partial.name == null) {
                  partial.name = n;
                  yield ToolCallStart(id: partial.id ?? '', name: n);
                }
                final args = fn['arguments'];
                if (args is String) partial.args.write(args);
              }
            }
          }
        }
        final fr = choice['finish_reason'];
        if (fr is String) finishReason = fr;
      }

      // Result assembly lives INSIDE this try (not after it): jsonDecode of the
      // streamed tool-call arguments can fail on a truncated or malformed
      // payload, and that must surface as a humanized StreamError rather than a
      // raw FormatException thrown out of the generator. Mirrors Anthropic's
      // single-try structure where message_stop assembly is also covered.
      //
      // A *malformed arguments* failure is recovered per call instead (tin-p2sq):
      // the block is emitted with `argumentsParseError` set so the agent can
      // hand the parse error back to the model, which then re-emits the call
      // with correct escaping. Models do emit invalid JSON here — DeepSeek
      // streaming a long quote-heavy `bash` one-liner was the reported case —
      // and killing the whole turn for it loses text that already streamed.
      final blocks = <ContentBlock>[];
      if (textBuf.isNotEmpty) blocks.add(TextBlock(textBuf.toString()));
      final indices = toolCalls.keys.toList()..sort();
      for (final i in indices) {
        final pc = toolCalls[i]!;
        final argsStr = pc.args.toString();
        Map<String, dynamic> input = const {};
        String? parseError;
        if (argsStr.isNotEmpty) {
          try {
            input = jsonDecode(argsStr) as Map<String, dynamic>;
          } on FormatException catch (e) {
            parseError = e.message;
          }
        }
        blocks.add(ToolUseBlock(
          id: pc.id ?? 'call_$i',
          name: pc.name ?? '',
          input: input,
          argumentsParseError: parseError,
        ));
      }
      final stopReason =
          finishReason == 'tool_calls' ? 'tool_use' : finishReason;
      final hasUsage = promptTokens > 0 || completionTokens > 0;
      yield MessageComplete(
        content: blocks,
        stopReason: stopReason,
        usage: hasUsage
            ? TokenUsage(
                inputTokens: promptTokens,
                outputTokens: completionTokens,
              )
            : null,
      );
    } catch (e) {
      yield StreamError(humanizeException(e));
      return;
    }
  }

  List<Map<String, dynamic>> _encodeMessages(
      String system, List<Message> messages) {
    final out = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
    ];
    for (final m in messages) {
      if (m.role == Role.user) {
        final results = m.content.whereType<ToolResultBlock>().toList();
        if (results.isNotEmpty) {
          for (final r in results) {
            out.add({
              'role': 'tool',
              'tool_call_id': r.toolUseId,
              'content': r.content,
            });
          }
        } else {
          final text = m.content
              .whereType<TextBlock>()
              .map((t) => t.text)
              .join('\n');
          out.add({'role': 'user', 'content': text});
        }
      } else {
        final texts = m.content.whereType<TextBlock>().toList();
        final toolUses = m.content.whereType<ToolUseBlock>().toList();
        final msg = <String, dynamic>{'role': 'assistant'};
        msg['content'] = texts.isEmpty
            ? null
            : texts.map((t) => t.text).join('\n');
        if (toolUses.isNotEmpty) {
          msg['tool_calls'] = toolUses
              .map((u) => {
                    'id': u.id,
                    'type': 'function',
                    'function': {
                      'name': u.name,
                      'arguments': jsonEncode(u.input),
                    },
                  })
              .toList();
        }
        out.add(msg);
      }
    }
    return out;
  }

  Map<String, dynamic> _encodeTool(ToolSchema t) => {
        'type': 'function',
        'function': {
          'name': t.name,
          'description': t.description,
          'parameters': t.inputSchema,
        },
      };
}

class _PartialCall {
  String? id;
  String? name;
  final StringBuffer args = StringBuffer();
}

/// A [ProviderBuilder] that constructs an [OpenAiCompatibleAdapter] tagged
/// with [label] (used in error messages). Convenience for the OpenAI-compatible
/// built-in descriptors so they needn't repeat the field forwarding.
ProviderBuilder openAiCompatibleBuilder(String label) => (c) =>
    OpenAiCompatibleAdapter(
      apiKey: c.apiKey,
      model: c.model,
      baseUrl: c.baseUrl,
      maxTokens: c.maxTokens,
      streamIdleTimeout: c.streamIdleTimeout,
      requestTimeout: c.requestTimeout,
      label: label,
      extraBody: c.extraBody,
    );
