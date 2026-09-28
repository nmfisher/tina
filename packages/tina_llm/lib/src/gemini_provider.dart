/// The Gemini wire: Google's `streamGenerateContent` format — the one
/// provider that speaks neither Anthropic messages nor OpenAI
/// chat-completions. Auth is `x-goog-api-key`; streaming is SSE via
/// `alt=sse`.
///
/// Wire quirks kept from the old engine: tool calls are addressed by
/// *name*, not id, and a `functionResponse` must echo the call's name —
/// so an id→name map is built from every prior turn before encoding.
/// Calls arrive complete in a single part (no incremental arguments), so
/// each yields one [ToolCallStart] with a synthetic id.
library;

import 'generation_options.dart';
import 'dart:async';
import 'dart:convert';

import 'package:tina_core/tina_core.dart';

import 'anthropic_provider.dart';
import 'streaming.dart';

/// The default Gemini origin: `/v1beta/models/{model}:streamGenerateContent?alt=sse`.
const String geminiBaseUrl = 'https://generativelanguage.googleapis.com/v1beta';

/// The full SSE path for a model. Trailing slashes are tolerated; the
/// version segment must be present (there is no bare-host default here).
String geminiStreamPath(String baseUrl, String model) {
  var b = baseUrl;
  while (b.endsWith('/')) {
    b = b.substring(0, b.length - 1);
  }
  return '$b/models/$model:streamGenerateContent?alt=sse';
}

/// Build an id→name map from every [ToolUseBlock] in history, so a later
/// [ToolResultBlock] (which carries only the id) can be encoded as a
/// `functionResponse` with the matching name.
Map<String, String> collectToolNames(List<Message> messages) {
  final map = <String, String>{};
  for (final m in messages) {
    if (m.isReasoningOnly) continue;
    for (final b in m.content) {
      if (b is ToolUseBlock) map[b.id] = b.name;
    }
  }
  return map;
}

/// The `contents` list. Reasoning is provider-private and never sent; a
/// reasoning-only transcript entry must not become an empty `contents`
/// element.
List<Map<String, dynamic>> geminiContents(
    List<Message> messages, Map<String, String> idToName) {
  final out = <Map<String, dynamic>>[];
  for (final m in messages) {
    if (m.isReasoningOnly) continue;
    final role = m.role == Role.user ? 'user' : 'model';
    final parts = <Map<String, dynamic>>[];
    for (final b in m.content) {
      if (b is TextBlock) {
        parts.add({'text': b.text});
      } else if (b is ToolUseBlock) {
        parts.add({
          'functionCall': {'name': b.name, 'args': b.input},
        });
      } else if (b is ToolResultBlock) {
        final name = idToName[b.toolUseId] ?? b.toolUseId;
        parts.add({
          'functionResponse': {
            'name': name,
            'response': {
              'name': name,
              'content': {'output': b.content},
            },
          },
        });
      }
    }
    if (parts.isNotEmpty) out.add({'role': role, 'parts': parts});
  }
  return out;
}

/// The full request body for a `streamGenerateContent` call.
Map<String, dynamic> geminiBody({
  required String system,
  required List<Message> messages,
  required List<ToolSchema> tools,
  int maxOutputTokens = 8192,
  Map<String, String>? idToName,
}) {
  final names = idToName ?? collectToolNames(messages);
  return {
    if (system.isNotEmpty)
      'systemInstruction': {
        'parts': [
          {'text': system},
        ],
      },
    'contents': geminiContents(messages, names),
    if (tools.isNotEmpty)
      'tools': [
        {
          'functionDeclarations': [
            for (final t in tools)
              {
                'name': t.name,
                'description': t.description,
                'parameters': t.inputSchema,
              },
          ],
        },
      ],
    'generationConfig': {'maxOutputTokens': maxOutputTokens},
  };
}

/// One Gemini call so far: synthetic id, name, arguments.
final class _GeminiCall {
  _GeminiCall(this.id, this.name, this.args);
  final String id;
  final String name;
  final Map<String, dynamic> args;
}

/// Accumulates the SSE envelopes of one response: answer text, tool
/// calls (each complete on arrival), finish reason, usage. Deltas pass
/// straight through; this holds only what the final message needs.
final class GeminiBuilder with WireBuilderState {
  final StringBuffer text = StringBuffer();
  final List<_GeminiCall> calls = [];
  String finishReason = 'STOP';
  int inputTokens = 0;
  int outputTokens = 0;

  /// True once the envelope closing the response arrived — `finishReason`
  /// set, or `usageMetadata` after it. Gemini has no explicit
  /// message-stop event; a stop reason is the end marker.
  bool sawStop = false;

  /// Apply one SSE envelope. Returns true when it carried a stop reason
  /// (the wire's end marker). Unknown shapes are ignored, never fatal.
  bool applyFrame(Map<String, dynamic> evt, List<StreamEvent> out) {
    final usage = evt['usageMetadata'];
    if (usage is Map<String, dynamic>) {
      inputTokens = (usage['promptTokenCount'] as num?)?.toInt() ?? inputTokens;
      outputTokens =
          (usage['candidatesTokenCount'] as num?)?.toInt() ?? outputTokens;
      if (evt['candidates'] == null) sawStop = true; // trailing usage-only
    }
    // An empty candidates list is a legal heartbeat envelope — not a
    // stop, not an error. Only `finishReason` (or trailing usage after
    // it) ends the response.
    final candidates = evt['candidates'];
    if (candidates is! List || candidates.isEmpty) return false;
    final cand = candidates.first;
    if (cand is! Map<String, dynamic>) return false;
    final content = cand['content'];
    if (content is Map<String, dynamic>) {
      final parts = content['parts'];
      if (parts is List) {
        for (final p in parts) {
          if (p is! Map<String, dynamic>) continue;
          final t = p['text'];
          if (t is String && t.isNotEmpty) {
            text.write(t);
            out.add(TextDelta(t));
          }
          final fc = p['functionCall'];
          if (fc is Map) {
            final name = (fc['name'] as String?) ?? '';
            final args = (fc['args'] as Map<String, dynamic>?) ??
                const <String, dynamic>{};
            final call = _GeminiCall(
              'gemini_call_${calls.length}',
              name,
              Map<String, dynamic>.from(args),
            );
            calls.add(call);
            out.add(ToolCallStart(id: call.id, name: name));
          }
        }
      }
    }
    final fr = cand['finishReason'];
    if (fr is String && fr.isNotEmpty) {
      finishReason = fr;
      sawStop = true;
    }
    return sawStop;
  }

  /// `STOP`→`end_turn`, `MAX_TOKENS`→`max_tokens`, else lowercased — the
  /// core's stop-reason vocabulary.
  static String mapFinishReason(String fr) => switch (fr) {
        'STOP' => 'end_turn',
        'MAX_TOKENS' => 'max_tokens',
        _ => fr.toLowerCase(),
      };

  /// The final message, or null when nothing was produced.
  MessageComplete? build() {
    final blocks = <ContentBlock>[];
    if (text.isNotEmpty) blocks.add(TextBlock(text.toString()));
    for (final tc in calls) {
      blocks.add(ToolUseBlock(id: tc.id, name: tc.name, input: tc.args));
    }
    if (blocks.isEmpty) return null;
    final hasUsage = inputTokens > 0 || outputTokens > 0;
    return MessageComplete(
      content: blocks,
      stopReason: calls.isNotEmpty ? 'tool_use' : mapFinishReason(finishReason),
      usage: hasUsage
          ? TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
          : null,
    );
  }
}

/// One Gemini endpoint: key from the environment (`x-goog-api-key`),
/// streamGenerateContent over the injected HTTP seam, SSE in, core
/// events out.
final class GeminiProvider extends LlmProvider {
  GeminiProvider({
    required String model,
    required String Function() tokenFrom,
    this.baseUrl = geminiBaseUrl,
    HttpEndpoint? endpoint,
    this.stallTimeout = const Duration(seconds: 120),
    this.generation = const GenerationOptions(),
  })  : _endpoint = endpoint ?? IoHttpEndpoint(endpoint: baseUrl),
        _tokenFrom = tokenFrom,
        super(model);

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
    final key = _tokenFrom();
    if (key.isEmpty) {
      // Fail closed before any request: a keyless call can only 400/401.
      yield const StreamError(
          'no API token: set the provider key environment variable '
          '(see the provider list)');
      return;
    }
    final HttpResponse response;
    try {
      response = await _endpoint.post(
        geminiStreamPath(baseUrl, model),
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': key,
        },
        body: encodeBody(generation.gemini(geminiBody(
          system: system,
          messages: messages,
          tools: tools,
          maxOutputTokens: 8192,
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
        buildBuilder: GeminiBuilder.new,
        apply: (b, frame, out) => (b as GeminiBuilder).applyFrame(frame, out),
        build: (b) {
          final builder = b as GeminiBuilder;
          return builder.sawStop ? builder.build() : null;
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
      retryAfter: retryAfter(response.headers),
    );
  }
}
