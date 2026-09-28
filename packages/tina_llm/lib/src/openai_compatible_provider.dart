/// The OpenAI-compatible wire: one implementation for the thirteen
/// descriptors that speak `/chat/completions` — OpenAI, OpenRouter,
/// Cerebras, DeepSeek, GLM, Grok, Hetzner, LongCat, Mistral, NVIDIA NIM,
/// Novita, and the two Qwen endpoints.
///
/// The request is `{model, stream, messages, tools}` with `system` folded
/// into the message list and tool calls round-tripping as
/// `assistant.tool_calls` / `role:"tool"` messages. Deltas stream as
/// `choices[0].delta`; reasoning-capable servers put hidden text in
/// `delta.reasoning_content`, which maps onto the core's reasoning events.
/// A tool call's arguments may arrive split across chunks, keyed by the
/// call's `index`.
library;

import 'generation_options.dart';
import 'dart:async';
import 'dart:convert';

import 'package:tina_core/tina_core.dart';

import 'anthropic_provider.dart';
import 'streaming.dart';

/// The wire path appended to a descriptor's base URL. Bases ending in a
/// version segment (`…/v1`, `…/v4`, `…/compatible-mode/v1`) take
/// `/chat/completions` directly; bare hosts get `/v1/` inserted.
String chatCompletionsPath(String baseUrl) {
  var b = baseUrl;
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  if (RegExp(r'/v\d+$').hasMatch(b)) return '$b/chat/completions';
  return '$b/v1/chat/completions';
}

/// One in-flight tool call: identity plus the argument JSON accumulated
/// so far, keyed by the call's `index` in the builder.
final class _PartialCall {
  String id = '';
  String name = '';
  bool announced = false;
  final StringBuffer args = StringBuffer();
}

/// Accumulates the frames of one chat-completions response into the
/// completion: answer text, reasoning text, tool calls by index, stop
/// reason, and usage. Deltas pass straight through to the caller; this
/// holds only what the final message needs.
final class ChatCompletionsBuilder with WireBuilderState {
  final StringBuffer text = StringBuffer();

  /// Reasoning text, from `delta.reasoning_content` when a server sends it.
  final StringBuffer reasoning = StringBuffer();

  final Map<int, _PartialCall> calls = {};

  /// `finish_reason` as the wire sent it, e.g. `tool_calls`, `stop`.
  String? finishReason;

  int? promptTokens;
  int? completionTokens;

  /// A malformed or failed frame's first complaint, to surface as a
  /// stream error.
  String? badFrame;

  /// True once an error frame was seen: the response ended in the
  /// provider's eyes, and no completion may be fabricated after it.
  bool errored = false;

  /// True once the wire said `data: [DONE]`.
  bool sawDone = false;

  /// Apply one SSE data payload. Returns true when it was the `[DONE]`
  /// sentinel or an error frame — this wire's end markers, standing in
  /// for the Anthropic wire's `message_stop`. Unknown shapes are
  /// ignored, never fatal.
  bool applyFrame(Map<String, dynamic> frame, List<StreamEvent> out) {
    if (frame['done'] == true) {
      sawDone = true;
      return true;
    }
    final error = frame['error'];
    if (error is Map<String, dynamic>) {
      // Some servers stream an error envelope instead of a response.
      errored = true;
      final message = error['message'];
      out.add(StreamError(
          'stream error: ${message is String ? message : jsonEncode(error)}'));
      return true;
    }
    final choices = frame['choices'];
    if (choices is! List) return false;
    for (final raw in choices) {
      if (raw is! Map<String, dynamic>) continue;
      final index = (raw['index'] as num?)?.toInt() ?? 0;
      if (index != 0) continue; // n>1 is not a tina turn.
      final delta = raw['delta'];
      if (delta is Map<String, dynamic>) {
        final rc = delta['reasoning_content'];
        if (rc is String && rc.isNotEmpty) {
          final starts = reasoning.isEmpty;
          reasoning.write(rc);
          out.add(ReasoningDelta(rc, startsBlock: starts));
        }
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          text.write(content);
          out.add(TextDelta(content));
        }
        final toolCalls = delta['tool_calls'];
        if (toolCalls is List) {
          for (final rawCall in toolCalls) {
            if (rawCall is! Map<String, dynamic>) continue;
            final i = (rawCall['index'] as num?)?.toInt() ?? 0;
            final call = calls.putIfAbsent(i, _PartialCall.new);
            final id = rawCall['id'];
            if (id is String && id.isNotEmpty) call.id = id;
            final fn = rawCall['function'];
            if (fn is Map<String, dynamic>) {
              final name = fn['name'];
              if (name is String && name.isNotEmpty) call.name = name;
              final args = fn['arguments'];
              if (args is String) call.args.write(args);
            }
            // Announce the call once, when its identity is complete —
            // argument deltas for an announced call are not new calls.
            if (!call.announced && call.id.isNotEmpty && call.name.isNotEmpty) {
              call.announced = true;
              out.add(ToolCallStart(id: call.id, name: call.name));
            }
          }
        }
      }
      final finish = raw['finish_reason'];
      if (finish is String && finish.isNotEmpty) finishReason = finish;
    }
    final usage = frame['usage'];
    if (usage is Map<String, dynamic>) {
      promptTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? promptTokens;
      completionTokens =
          (usage['completion_tokens'] as num?)?.toInt() ?? completionTokens;
    }
    return false;
  }

  /// The final message, or null when nothing was produced. A tool call
  /// whose argument JSON does not parse becomes a block with
  /// [ToolUseBlock.argumentsParseError] — the core's shape for that case.
  MessageComplete? build() {
    final blocks = <ContentBlock>[];
    if (text.isNotEmpty) blocks.add(TextBlock(text.toString()));
    for (final entry in calls.entries) {
      final call = entry.value;
      var input = const <String, dynamic>{};
      String? parseError;
      if (call.args.isNotEmpty) {
        try {
          final decoded = jsonDecode(call.args.toString());
          if (decoded is Map<String, dynamic>) {
            input = decoded;
          } else {
            parseError = 'tool arguments were ${decoded.runtimeType}';
          }
        } on FormatException catch (e) {
          parseError = 'tool arguments JSON did not parse: ${e.message}';
        }
      }
      blocks.add(ToolUseBlock(
        id: call.id.isEmpty ? 'call_${entry.key}' : call.id,
        name: call.name,
        input: input,
        argumentsParseError: parseError,
      ));
    }
    if (blocks.isEmpty) return null;
    return MessageComplete(
      content: blocks,
      stopReason: finishReason ?? (calls.isNotEmpty ? 'tool_calls' : 'stop'),
      usage: (promptTokens != null || completionTokens != null)
          ? TokenUsage(
              inputTokens: promptTokens ?? 0,
              outputTokens: completionTokens ?? 0)
          : null,
      diagnostics:
          CompletionDiagnostics(reasoningObserved: reasoning.isNotEmpty),
    );
  }
}

/// The wire's message list, with tool calls and results round-tripped in
/// the wire's own shapes. The core transcript is Anthropic-shaped (the
/// types were copied from it), so this is the translation point:
/// `tool_use` becomes `assistant.tool_calls`, a following `tool_result`
/// becomes a `role:"tool"` message.
List<Map<String, dynamic>> chatCompletionsMessages(List<Message> messages) {
  final out = <Map<String, dynamic>>[];
  for (final m in messages) {
    if (m.reasoning.isNotEmpty) continue; // reasoning is provider-private
    if (m.role == Role.user) {
      // A user turn's tool results ARE the tool's answer on this wire.
      for (final b in m.content) {
        if (b is ToolResultBlock) {
          out.add({
            'role': 'tool',
            'tool_call_id': b.toolUseId,
            'content': b.content,
          });
        }
      }
      final rest = [
        for (final b in m.content)
          if (b is TextBlock) b.text,
      ];
      if (rest.isNotEmpty) {
        out.add({'role': 'user', 'content': rest.join('\n')});
      }
      continue;
    }
    // Assistant: the model's own words and its calls.
    final toolCalls = <Map<String, dynamic>>[];
    final textParts = <String>[];
    for (final b in m.content) {
      if (b is TextBlock) {
        textParts.add(b.text);
      } else if (b is ToolUseBlock) {
        toolCalls.add({
          'id': b.id,
          'type': 'function',
          'function': {'name': b.name, 'arguments': jsonEncode(b.input)},
        });
      }
    }
    if (toolCalls.isNotEmpty) {
      out.add({
        'role': 'assistant',
        if (textParts.isNotEmpty) 'content': textParts.join('\n'),
        'tool_calls': toolCalls,
      });
    } else if (textParts.isNotEmpty) {
      out.add({'role': 'assistant', 'content': textParts.join('\n')});
    }
  }
  return out;
}

/// The full request body for a chat-completions call. The system prompt
/// rides at the head of the message list — this wire has no system field
/// of its own.
Map<String, dynamic> chatCompletionsBody({
  required String model,
  required String system,
  required List<Message> messages,
  required List<ToolSchema> tools,
  int maxOutputTokens = 8192,
}) {
  final rest = chatCompletionsMessages(messages);
  return {
    'model': model,
    'stream': true,
    'max_tokens': maxOutputTokens,
    'messages': [
      if (system.isNotEmpty) {'role': 'system', 'content': system},
      ...rest,
    ],
    if (tools.isNotEmpty)
      'tools': [
        for (final t in tools)
          {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.inputSchema,
            },
          },
      ],
  };
}

/// One OpenAI-compatible endpoint: bearer token from the environment,
/// chat-completions over the injected HTTP seam, SSE in, core events out.
final class OpenAiCompatibleProvider extends LlmProvider {
  OpenAiCompatibleProvider({
    required String model,
    required this.baseUrl,
    required String Function() tokenFrom,
    HttpEndpoint? endpoint,
    this.stallTimeout = const Duration(seconds: 120),
    this.generation = const GenerationOptions(),
  })  : _endpoint = endpoint ?? IoHttpEndpoint(endpoint: baseUrl),
        _tokenFrom = tokenFrom,
        super(model);

  /// The descriptor's base URL, e.g. `https://api.openai.com/v1`. The
  /// chat-completions path is resolved against it per send.
  final String baseUrl;

  final HttpEndpoint _endpoint;
  final String Function() _tokenFrom;
  final Duration stallTimeout;
  final GenerationOptions generation;

  @override
  void close() {
    final e = _endpoint;
    if (e is IoHttpEndpoint) e.close();
  }

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    final token = _tokenFrom();
    if (token.isEmpty) {
      // Fail closed before any request: a keyless call can only 401.
      yield const StreamError(
          'no API token: set the provider key environment variable '
          '(see the provider list)');
      return;
    }
    final HttpResponse response;
    try {
      response = await _endpoint.post(
        chatCompletionsPath(baseUrl),
        headers: {
          'content-type': 'application/json',
          'accept': 'text/event-stream',
          'authorization': 'Bearer $token',
        },
        body: encodeBody(generation.openAi(chatCompletionsBody(
          model: model,
          system: system,
          messages: messages,
          tools: tools,
        ))),
      );
    } catch (e) {
      yield StreamError('request failed: transport error ($e)');
      return;
    }
    if (response.statusCode != 200) {
      yield await _httpError(response);
      return;
    }
    yield* pumpSse(
      response.body,
      WireProtocol(
        buildBuilder: ChatCompletionsBuilder.new,
        apply: (b, frame, out) =>
            (b as ChatCompletionsBuilder).applyFrame(frame, out),
        build: (b) {
          final builder = b as ChatCompletionsBuilder;
          // No `[DONE]`, no completion: the wire's own end marker is the
          // only proof the response finished on the server's terms.
          return builder.sawDone ? builder.build() : null;
        },
      ),
      stallTimeout: stallTimeout,
    );
  }

  Future<StreamError> _httpError(HttpResponse response) async {
    final text = await response.body
        .transform(utf8.decoder)
        .fold(StringBuffer(), (b, c) => b..write(c))
        .then((b) => b.toString());
    var message = 'HTTP ${response.statusCode}';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'];
        if (err is Map<String, dynamic> && err['message'] is String) {
          message = '$message: ${err['message']}';
        } else if (decoded['message'] is String) {
          message = '$message: ${decoded['message']}';
        }
      }
    } catch (_) {
      // Non-JSON error body: the status line alone is the message.
    }
    return StreamError(
      message.length > 500 ? '${message.substring(0, 500)}…' : message,
      statusCode: response.statusCode,
      requiresUserAction:
          response.statusCode == 401 || response.statusCode == 403,
      providerCode: response.statusCode == 429 ? 'rate_limited' : null,
      retryAfter: retryAfter(response.headers),
    );
  }
}
