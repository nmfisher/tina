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

/// Google Gemini — native wire format (`/v1beta/models/{model}:streamGenerateContent`),
/// distinct from OpenAI's. Auth is `x-goog-api-key`. Streaming uses `alt=sse`.
///
/// Tool round-trip: Gemini addresses function calls by *name*, not id, and a
/// `functionResponse` must echo the call's name. Our [ToolResultBlock] carries
/// only the call id, so the builder reconstructs id→name by scanning prior
/// assistant turns (see [_collectToolNames]). Function calls arrive complete
/// in a single part (Gemini doesn't stream `arguments` incrementally), so each
/// yields one [ToolCallStart] with a synthetic id.
class GeminiProvider extends LlmProvider {
  final String apiKey;
  final int maxTokens;
  final String baseUrl;
  final Duration streamIdleTimeout;
  final Duration requestTimeout;
  final http.Client _client;

  GeminiProvider({
    required this.apiKey,
    required String model,
    this.maxTokens = 8192,
    this.baseUrl = 'https://generativelanguage.googleapis.com/v1beta',
    this.streamIdleTimeout = defaultStreamIdleTimeout,
    this.requestTimeout = defaultRequestTimeout,
    http.Client? client,
  })  : _client = client ?? http.Client(),
        super(model);

  @override
  void close() => _client.close();

  Uri _endpoint() {
    var b = baseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return Uri.parse('$b/models/$model:streamGenerateContent?alt=sse');
  }

  http.Request _buildRequest(String body) {
    final r = http.Request('POST', _endpoint());
    r.headers.addAll({
      'content-type': 'application/json',
      'x-goog-api-key': apiKey,
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
    final idToName = _collectToolNames(messages);
    final bodyStr = jsonEncode({
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system}
          ],
        },
      'contents': _encodeMessages(messages, idToName),
      if (tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': tools.map(_encodeTool).toList(),
          }
        ],
      'generationConfig': {'maxOutputTokens': maxTokens},
    });
    final bodyBytes = utf8.encode(bodyStr).length;
    // Size-scaled defaults (#23c / #24b): same contract as all providers.
    final effectiveRequestTimeout = requestTimeout == defaultRequestTimeout
        ? scaledRequestTimeout(bodyBytes)
        : requestTimeout;
    final effectiveStreamIdleTimeout =
        streamIdleTimeout == defaultStreamIdleTimeout
            ? scaledStreamIdleTimeout(bodyBytes)
            : streamIdleTimeout;
    HttpLog.log(_endpoint(), bodyStr);

    final http.StreamedResponse resp;
    try {
      resp = await sendOnce(_client, () => _buildRequest(bodyStr),
          requestTimeout: effectiveRequestTimeout);
    } catch (e) {
      yield StreamError(humanizeException(e), transient: isTransientException(e));
      return;
    }
    if (resp.statusCode != 200) {
      final text = await resp.stream.bytesToString();
      yield StreamError(humanizeHttpError('Gemini', resp.statusCode, text),
          statusCode: resp.statusCode,
          retryAfter: parseRetryAfter(resp.headers['retry-after']),
          // #46 (a): error bodies can carry usageMetadata — book it.
          usage: parseErrorUsage(text));
      return;
    }

    final textBuf = StringBuffer();
    final toolCalls = <_GeminiCall>[];
    var finishReason = 'STOP';
    var inputTokens = 0;
    var outputTokens = 0;

    // WHY (#23 / #24): stream-idle timeout must name its flag — same anonymous
    // string as request-timeout made operators change the wrong knob.
    final rawEvents = resp.stream.timeout(
      effectiveStreamIdleTimeout,
      onTimeout: (sink) {
        sink.addError(TimeoutException(
          'no stream events for ${effectiveStreamIdleTimeout.inSeconds}s — '
          'raise with --stream-idle-timeout',
          effectiveStreamIdleTimeout,
        ));
        sink.close();
      },
    );
    final events = parseSse(rawEvents);
    try {
      await for (final payload in events) {
        final Map<String, dynamic> evt;
        try {
          evt = jsonDecode(payload) as Map<String, dynamic>;
        } catch (e) {
          _log.fine('skipped non-JSON SSE line', e);
          continue;
        }
        final usage = evt['usageMetadata'];
        if (usage is Map) {
          inputTokens = (usage['promptTokenCount'] as int?) ?? inputTokens;
          outputTokens =
              (usage['candidatesTokenCount'] as int?) ?? outputTokens;
        }
        final candidates = evt['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) continue;
        final cand = candidates.first as Map<String, dynamic>;

        final content = cand['content'] as Map<String, dynamic>?;
        if (content != null) {
          final parts = content['parts'] as List?;
          if (parts != null) {
            for (final p in parts) {
              final part = p as Map<String, dynamic>;
              final t = part['text'];
              if (t is String && t.isNotEmpty) {
                textBuf.write(t);
                yield TextDelta(t);
              }
              final fc = part['functionCall'];
              if (fc is Map) {
                final name = (fc['name'] as String?) ?? '';
                final args = (fc['args'] as Map<String, dynamic>?) ?? const {};
                final call = _GeminiCall(
                  id: 'gemini_call_${toolCalls.length}',
                  name: name,
                  args: Map<String, dynamic>.from(args),
                );
                toolCalls.add(call);
                yield ToolCallStart(id: call.id, name: name);
              }
            }
          }
        }
        final fr = cand['finishReason'];
        if (fr is String) finishReason = fr;
      }
    } catch (e) {
      yield StreamError(humanizeException(e));
      return;
    }

    final blocks = <ContentBlock>[];
    if (textBuf.isNotEmpty) blocks.add(TextBlock(textBuf.toString()));
    for (final tc in toolCalls) {
      blocks.add(ToolUseBlock(id: tc.id, name: tc.name, input: tc.args));
    }
    final stopReason =
        toolCalls.isNotEmpty ? 'tool_use' : _mapFinishReason(finishReason);
    final hasUsage = inputTokens > 0 || outputTokens > 0;
    yield MessageComplete(
      content: blocks,
      stopReason: stopReason,
      usage: hasUsage
          ? TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
          : null,
    );
  }

  /// Build an id→name map from every [ToolUseBlock] in history, so a later
  /// [ToolResultBlock] (which carries only the id) can be encoded as a Gemini
  /// `functionResponse` with the matching name.
  Map<String, String> _collectToolNames(List<Message> messages) {
    final map = <String, String>{};
    for (final m in messages) {
      for (final b in m.content) {
        if (b is ToolUseBlock) map[b.id] = b.name;
      }
    }
    return map;
  }

  List<Map<String, dynamic>> _encodeMessages(
      List<Message> messages, Map<String, String> idToName) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
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

  Map<String, dynamic> _encodeTool(ToolSchema t) => {
        'name': t.name,
        'description': t.description,
        'parameters': t.inputSchema,
      };

  String _mapFinishReason(String fr) {
    switch (fr) {
      case 'STOP':
        return 'end_turn';
      case 'MAX_TOKENS':
        return 'max_tokens';
      default:
        return fr.toLowerCase();
    }
  }
}

class _GeminiCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  _GeminiCall({required this.id, required this.name, required this.args});
}
