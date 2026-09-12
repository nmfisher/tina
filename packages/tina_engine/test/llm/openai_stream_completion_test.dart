import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';

String _event(Map<String, Object?> event) => 'data: ${jsonEncode(event)}\n\n';
String _chunk(Map<String, Object?> delta, {String? finish}) => _event({
      'choices': [
        {'delta': delta, if (finish != null) 'finish_reason': finish}
      ],
    });
const _done = 'data: [DONE]\n\n';

class _Client extends http.BaseClient {
  final String body;
  int calls = 0;
  _Client(this.body);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    // Split every byte to exercise framing across transport chunks.
    return http.StreamedResponse(
        Stream.fromIterable(utf8.encode(body).map((b) => [b])), 200);
  }
}

Future<List<StreamEvent>> _parse(String body) async {
  final provider = OpenAiCompatibleAdapter(
      apiKey: '', model: 'fixture', label: 'GLM', client: _Client(body));
  try {
    return await provider.send(system: '', messages: [], tools: []).toList();
  } finally {
    provider.close();
  }
}

void main() {
  for (final body in [
    '',
    ': heartbeat\n\n',
    _chunk({'content': 'partial answer'}),
    _chunk({
      'tool_calls': [
        {
          'index': 0,
          'id': 'c1',
          'function': {
            'name': 'write',
            'arguments': '{"path":"x"}',
          }
        }
      ]
    }),
  ]) {
    test('EOF without completion marker is a stream error: $body', () async {
      final events = await _parse(body);
      expect(events.whereType<MessageComplete>(), isEmpty);
      final error = events.whereType<StreamError>().single;
      expect(error.error.toString(), contains('without a completion marker'));
      expect(isTransportRetryable(error), isTrue);
    });
  }

  for (final ending in [
    _done,
    _chunk({}, finish: 'stop'),
    _chunk({}, finish: 'stop') + _done
  ]) {
    test('accepts explicit completion with ending $ending', () async {
      final events = await _parse(_chunk({'content': 'hello'}) + ending);
      expect(events.whereType<StreamError>(), isEmpty);
      final complete = events.whereType<MessageComplete>().single;
      expect((complete.content.single as TextBlock).text, 'hello');
      expect(complete.stopReason, 'stop');
    });
  }

  test('a genuinely empty completed stream stays eligible for empty retry',
      () async {
    final events = await _parse(_chunk({}, finish: 'stop') + _done);
    final complete = events.whereType<MessageComplete>().single;
    expect(classifyEmptyCompletion(complete.content, complete.stopReason),
        EmptyCompletionCause.transient);
  });

  for (final prefix in [
    '',
    _chunk({'content': 'partial'})
  ]) {
    test('stream error wins over any partial response: $prefix', () async {
      final events = await _parse(prefix +
          _event({
            'error': {'code': 1113, 'message': '余额不足或无可用资源包,请充值。'},
            'usage': {'prompt_tokens': 5, 'completion_tokens': 1},
          }) +
          _chunk({}, finish: 'stop') +
          _done);
      expect(events.whereType<MessageComplete>(), isEmpty);
      final error = events.whereType<StreamError>().single;
      expect(error.providerCode, '1113');
      expect(error.requiresUserAction, isTrue);
      expect(error.statusCode, isNull,
          reason: 'HTTP 200 is not an error status');
      expect(error.error.toString(), contains('GLM stream error'));
      expect(error.error.toString(), contains('Action required:'));
      expect(error.usage!.inputTokens, 5);
    });
  }

  test(
      'stream rate limit retains retry classification without inventing HTTP status',
      () async {
    final events = await _parse(_event({
      'error': {'code': '1302', 'message': 'rate limit'},
    }));
    final error = events.whereType<StreamError>().single;
    expect(error.statusCode, isNull);
    expect(isTransportRetryable(error), isTrue);
  });

  test('embedded HTTP error status is preserved', () async {
    final events = await _parse(_event({
      'error': {'code': 503, 'message': 'unavailable'},
    }));
    expect(events.whereType<StreamError>().single.statusCode, 503);
    expect(
        isTransportRetryable(events.whereType<StreamError>().single), isTrue);
  });

  test('usage before a stream error is retained', () async {
    final events = await _parse(_event({
          'usage': {'prompt_tokens': 12, 'completion_tokens': 3},
        }) +
        _event({
          'error': {'code': '1113', 'message': 'balance'}
        }));
    expect(events.whereType<StreamError>().single.usage!.inputTokens, 12);
  });

  for (final finish in ['length', 'content_filter']) {
    test('thinking filtering preserves $finish on the same chunk', () async {
      final events = await _parse(_chunk({'content': '<|channel>thought'}) +
          _chunk({'content': 'still thinking'}, finish: finish));
      final complete = events.whereType<MessageComplete>().single;
      expect(complete.content, isEmpty);
      expect(complete.stopReason, finish);
      expect(events.whereType<TextDelta>(), isEmpty);
    });
  }

  test('filtering thinking does not discard tool calls in the same chunk',
      () async {
    final events = await _parse(_chunk({'content': '<|channel>thought'}) +
        _chunk({
          'content': 'thinking',
          'tool_calls': [
            {
              'index': 0,
              'id': 'c1',
              'function': {'name': 'read', 'arguments': '{}'},
            }
          ]
        }, finish: 'tool_calls'));
    final complete = events.whereType<MessageComplete>().single;
    expect(complete.stopReason, 'tool_use');
    expect((complete.content.single as ToolUseBlock).name, 'read');
    expect(events.whereType<ToolCallStart>(), hasLength(1));
  });

  for (final body in [
    _event({
      'error': {'code': '1113', 'message': 'balance'}
    }),
    _chunk({'content': '<|channel>thought'}) +
        _chunk({'content': 'thinking'}, finish: 'length'),
  ]) {
    test('terminal stream outcome stops the real agent retry ladders: $body',
        () async {
      final client = _Client(body);
      final provider = RetryingProvider(OpenAiCompatibleAdapter(
          apiKey: '', model: 'fixture', label: 'GLM', client: client));
      addTearDown(provider.close);
      final sink = FakeAgentSink();
      final agent = Agent(
          provider: provider,
          tools: ToolRegistry([]),
          sink: sink,
          system: 'sys',
          policy: PermissionPolicy(),
          transportRetryAttempts: 3,
          asker: (_) async => PermissionResponse.denyOnce);
      await agent.run(history: [], userInput: 'hi');
      expect(client.calls, 1);
      expect(agent.abortedKind, AbortedKind.providerTerminal);
      expect(sink.notices.any((n) => n.message.contains('empty completion')),
          isFalse);
    });
  }
}
