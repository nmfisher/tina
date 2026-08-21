import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_http.dart';

void main() {
  group('OpenAiCompatibleAdapter.chatEndpoint', () {
    test('bare host gets /v1 prepended (OpenAI, DeepSeek default)', () {
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://api.openai.com'),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://api.deepseek.com'),
        'https://api.deepseek.com/v1/chat/completions',
      );
    });

    test('a trailing slash is stripped before joining', () {
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://api.openai.com/'),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('a path already ending in /v1 appends only /chat/completions', () {
      // Groq, OpenRouter, xAI all publish /v1 bases.
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://api.groq.com/openai/v1'),
        'https://api.groq.com/openai/v1/chat/completions',
      );
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://openrouter.ai/api/v1'),
        'https://openrouter.ai/api/v1/chat/completions',
      );
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://api.x.ai/v1'),
        'https://api.x.ai/v1/chat/completions',
      );
    });

    test('GLM /api/paas/v4 is treated as already versioned (the motivating case)', () {
      // A naive "append /v1" rule would yield .../paas/v4/v1/chat/completions.
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://open.bigmodel.cn/api/paas/v4'),
        'https://open.bigmodel.cn/api/paas/v4/chat/completions',
      );
    });

    test('local servers: bare host vs /v1-suffixed', () {
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('http://localhost:11434'),
        'http://localhost:11434/v1/chat/completions',
      );
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('http://localhost:11434/v1'),
        'http://localhost:11434/v1/chat/completions',
      );
    });

    test('multi-digit version segments (/v12) are recognized', () {
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://example.com/v12'),
        'https://example.com/v12/chat/completions',
      );
    });

    test('a non-versioned path falls back to /v1', () {
      expect(
        OpenAiCompatibleAdapter.chatEndpoint('https://proxy.example.com/llm'),
        'https://proxy.example.com/llm/v1/chat/completions',
      );
    });
  });

  group('request encoding', () {
    test('injects system as a leading system message', () async {
      final cap = CapturedRequest();
      final provider = OpenAiCompatibleAdapter(
          apiKey: 'k', model: 'm', client: cap.client);
      await provider
          .send(
            system: 'you are tina',
            messages: const [
              Message(role: Role.user, content: [TextBlock('hi')])
            ],
            tools: const [],
          )
          .toList();

      final messages = (jsonDecode(cap.body!) as Map)['messages'] as List;
      expect((messages.first as Map)['role'], 'system');
      expect((messages.first as Map)['content'], 'you are tina');
      expect((messages[1] as Map)['role'], 'user');
    });

    test('encodes a tool_result as role: tool with tool_call_id', () async {
      final cap = CapturedRequest();
      final provider = OpenAiCompatibleAdapter(
          apiKey: 'k', model: 'm', client: cap.client);
      await provider
          .send(
            system: '',
            messages: const [
              Message(role: Role.assistant, content: [
                ToolUseBlock(id: 'call_1', name: 'bash', input: {'command': 'ls'}),
              ]),
              Message(role: Role.user, content: [
                ToolResultBlock(toolUseId: 'call_1', content: 'file.txt'),
              ]),
            ],
            tools: const [],
          )
          .toList();

      final messages = (jsonDecode(cap.body!) as Map)['messages'] as List;
      // messages = [system, assistant(tool_use), tool(result)]
      final toolMsg = messages[2] as Map;
      expect(toolMsg['role'], 'tool');
      expect(toolMsg['tool_call_id'], 'call_1');
      expect(toolMsg['content'], 'file.txt');
    });

    test('encodes assistant text + tool_use as content + tool_calls', () async {
      final cap = CapturedRequest();
      final provider = OpenAiCompatibleAdapter(
          apiKey: 'k', model: 'm', client: cap.client);
      await provider
          .send(
            system: '',
            messages: const [
              Message(role: Role.assistant, content: [
                TextBlock('running it'),
                ToolUseBlock(id: 'call_1', name: 'bash', input: {'command': 'ls'}),
              ]),
            ],
            tools: const [],
          )
          .toList();

      final messages = (jsonDecode(cap.body!) as Map)['messages'] as List;
      final asst = messages[1] as Map;
      expect(asst['role'], 'assistant');
      expect(asst['content'], 'running it');
      final calls = asst['tool_calls'] as List;
      expect(calls, hasLength(1));
      final fn = (calls.first as Map)['function'] as Map;
      expect(fn['name'], 'bash');
      // input map is JSON-encoded into the `arguments` string
      expect(jsonDecode(fn['arguments'] as String), {'command': 'ls'});
    });

    test('omits the authorization header when the key is empty', () async {
      final empty = CapturedRequest();
      await OpenAiCompatibleAdapter(apiKey: '', model: 'm', client: empty.client)
          .send(system: '', messages: const [], tools: const [])
          .toList();
      expect(empty.headers.containsKey('authorization'), isFalse);

      final keyed = CapturedRequest();
      await OpenAiCompatibleAdapter(apiKey: 'sekret', model: 'm', client: keyed.client)
          .send(system: '', messages: const [], tools: const [])
          .toList();
      expect(keyed.headers['authorization'], 'Bearer sekret');
    });

    test('extraBody is merged into the request body (last-wins)', () async {
      final cap = CapturedRequest();
      final provider = OpenAiCompatibleAdapter(
        apiKey: 'k',
        model: 'google/gemma-4-31b-it',
        // Mirrors how a model would enable NIM thinking via chat_template_kwargs.
        extraBody: {'chat_template_kwargs': {'enable_thinking': true}},
        client: cap.client,
      );
      await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();
      final body = jsonDecode(cap.body!) as Map<String, dynamic>;
      expect(body['model'], 'google/gemma-4-31b-it');
      expect(body['chat_template_kwargs'], {'enable_thinking': true});
      // Default fields still present alongside the extras.
      expect(body['stream'], true);
      expect(body['max_tokens'], 8192);
    });

    test('an empty extraBody leaves the default body untouched', () async {
      final cap = CapturedRequest();
      await OpenAiCompatibleAdapter(apiKey: 'k', model: 'm', client: cap.client)
          .send(system: '', messages: const [], tools: const [])
          .toList();
      final body = jsonDecode(cap.body!) as Map<String, dynamic>;
      expect(body.keys.toSet(),
          {'model', 'max_tokens', 'messages', 'stream', 'stream_options'});
    });
  });

  group('response parsing', () {
    test('streams delta.content as TextDelta and surfaces usage + stopReason',
        () async {
      final sse = [
        'data: ${jsonEncode({
              "choices": [
                {"index": 0, "delta": {"content": "Hel"}}
              ]
            })}',
        'data: ${jsonEncode({
              "choices": [
                {"index": 0, "delta": {"content": "lo"}}
              ]
            })}',
        'data: ${jsonEncode({
              "choices": [
                {"index": 0, "delta": {}, "finish_reason": "stop"}
              ]
            })}',
        'data: ${jsonEncode({
              "usage": {"prompt_tokens": 5, "completion_tokens": 2}
            })}',
        'data: [DONE]',
        '',
      ].join('\n');

      final provider = OpenAiCompatibleAdapter(
          apiKey: 'k', model: 'm', client: ScriptedSseClient(sse));
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();

      expect(events.whereType<TextDelta>().map((e) => e.text).toList(),
          ['Hel', 'lo']);
      final complete = events.whereType<MessageComplete>().single;
      expect((complete.content.single as TextBlock).text, 'Hello');
      expect(complete.stopReason, 'stop');
      expect(complete.usage!.inputTokens, 5);
      expect(complete.usage!.outputTokens, 2);
    });

    test('assembles streamed tool_calls argument fragments and maps stop reason',
        () async {
      // The arguments JSON is split across two deltas: '{"comm' + 'and":"ls"}'.
      final sse = [
        'data: ${jsonEncode({
              "choices": [
                {
                  "index": 0,
                  "delta": {
                    "tool_calls": [
                      {
                        "index": 0,
                        "id": "call_1",
                        "function": {"name": "bash", "arguments": '{"comm'}
                      }
                    ]
                  }
                }
              ]
            })}',
        'data: ${jsonEncode({
              "choices": [
                {
                  "index": 0,
                  "delta": {
                    "tool_calls": [
                      {
                        "index": 0,
                        "function": {"arguments": 'and":"ls"}'}
                      }
                    ]
                  }
                }
              ]
            })}',
        'data: ${jsonEncode({
              "choices": [
                {"index": 0, "delta": {}, "finish_reason": "tool_calls"}
              ]
            })}',
        'data: [DONE]',
        '',
      ].join('\n');

      final provider = OpenAiCompatibleAdapter(
          apiKey: 'k', model: 'm', client: ScriptedSseClient(sse));
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();

      expect(events.whereType<ToolCallStart>().single.name, 'bash');
      final complete = events.whereType<MessageComplete>().single;
      final use = complete.content.whereType<ToolUseBlock>().single;
      expect(use.id, 'call_1');
      expect(use.input, {'command': 'ls'});
      // OpenAI 'tool_calls' finish reason → our canonical 'tool_use'.
      expect(complete.stopReason, 'tool_use');
    });

    // Regression guard: muse-glimmer-30b on NIM mangles streamed tool names
    // under real agent payload sizes (see ~/.tina/tina.log "unknown tool"
    // notices; tool/nim_toolcall_probe.dart --real reproduces). Two shapes:
    // a chat-template token fused on (`ls<|message|>`) and the first
    // argument key fused on (`ls.path`). Both must reach the agent repaired.
    test('mangled streamed tool names are repaired (muse-glimmer)', () async {
      final sse = [
        'data: ${jsonEncode({
              "choices": [
                {
                  "index": 0,
                  "delta": {
                    "tool_calls": [
                      {
                        "index": 0,
                        "id": "call_1",
                        "function": {
                          "name": 'ls<|message|>',
                          "arguments": '{}'
                        }
                      }
                    ]
                  }
                }
              ]
            })}',
        'data: ${jsonEncode({
              "choices": [
                {
                  "index": 0,
                  "delta": {
                    "tool_calls": [
                      {
                        "index": 1,
                        "id": "call_2",
                        "function": {
                          "name": 'read.filePath',
                          "arguments": '{"filePath": "pubspec.yaml"}'
                        }
                      }
                    ]
                  }
                }
              ]
            })}',
        'data: ${jsonEncode({
              "choices": [
                {"index": 0, "delta": {}, "finish_reason": "tool_calls"}
              ]
            })}',
        'data: [DONE]',
        '',
      ].join('\n');

      final provider = OpenAiCompatibleAdapter(
          apiKey: 'k', model: 'm', client: ScriptedSseClient(sse));
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();

      // The progress event names the tool the agent will actually run.
      final starts = events.whereType<ToolCallStart>().toList();
      expect(starts.map((e) => e.name), ['ls', 'read']);

      final complete = events.whereType<MessageComplete>().single;
      final uses = complete.content.whereType<ToolUseBlock>().toList();
      expect(uses.map((u) => u.name), ['ls', 'read']);
      // Arguments pass through untouched — only the NAME is repaired.
      expect(uses.last.input, {'filePath': 'pubspec.yaml'});
    });
  });

  group('repairStreamedToolName', () {
    test('template control tokens are stripped', () {
      expect(repairStreamedToolName('ls<|message|>'), 'ls');
      expect(repairStreamedToolName('bash<|message|>'), 'bash');
      expect(repairStreamedToolName('<|tool_call|>bash<|end|>'), 'bash');
    });

    test('a fused argument key is dropped from the name', () {
      expect(repairStreamedToolName('ls.path'), 'ls');
      expect(repairStreamedToolName('read.filePath'), 'read');
    });

    test('clean names pass through unchanged, null/empty tolerate', () {
      expect(repairStreamedToolName('bash'), 'bash');
      expect(repairStreamedToolName(' web_search '), 'web_search');
      expect(repairStreamedToolName(null), '');
      expect(repairStreamedToolName(''), '');
    });

    test('idempotent', () {
      const mangled = 'ls<|message|>';
      final once = repairStreamedToolName(mangled);
      expect(repairStreamedToolName(once), once);
    });
  });

  group('error handling', () {
    test('non-200 yields a StreamError with the humanized body', () async {
      final provider = OpenAiCompatibleAdapter(
        apiKey: 'k',
        model: 'm',
        label: 'OpenAI',
        client: ScriptedSseClient(
          jsonEncode({'error': {'message': 'bad request'}}),
          status: 400,
        ),
      );
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();
      expect(events.whereType<StreamError>().single.error, 'OpenAI 400: bad request');
      // The status rides along so the rate-limit adapter can react to 429s
      // without string-matching the humanized text.
      expect(events.whereType<StreamError>().single.statusCode, 400);
    });

    // Regression guard: a model that streams tool arguments which are not valid
    // JSON must surface as a humanized StreamError, not a thrown FormatException
    // out of the generator. Previously the post-loop jsonDecode sat outside the
    // SSE try/catch; the assembly is now inside it.
    //
    // tin-p2sq tightened this further: the failure is recovered *per call* —
    // the block is delivered with `argumentsParseError` set so the agent can
    // hand the parse error back to the model instead of aborting the turn.
    // The two tests below pin that behaviour; a StreamError is no longer
    // emitted for a malformed-arguments stream.
    test('malformed streamed tool arguments recover per call (tin-p2sq)',
        () async {
      final sse = [
        'data: ${jsonEncode({
              "choices": [
                {
                  "index": 0,
                  "delta": {
                    "content": "Counting the tests first.",
                    "tool_calls": [
                      {
                        "index": 0,
                        "id": "call_1",
                        "function": {
                          "name": "bash",
                          // An unterminated string: the model opened the
                          // command value and never closed it — the exact
                          // shape DeepSeek streamed for a quote-heavy
                          // one-liner.
                          "arguments": '{"command":"for f in *; do echo '
                        }
                      }
                    ]
                  }
                }
              ]
            })}',
        'data: ${jsonEncode({
              "choices": [
                {"index": 0, "delta": {}, "finish_reason": "tool_calls"}
              ]
            })}',
        'data: [DONE]',
        '',
      ].join('\n');
      final provider = OpenAiCompatibleAdapter(
          apiKey: 'k', model: 'm', client: ScriptedSseClient(sse));
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();

      expect(events.whereType<StreamError>(), isEmpty,
          reason: 'a malformed call must not kill the streamed response');
      final complete = events.whereType<MessageComplete>().single;
      // Text that already streamed survives.
      expect((complete.content[0] as TextBlock).text, 'Counting the tests first.');
      final use = complete.content.whereType<ToolUseBlock>().single;
      expect(use.id, 'call_1');
      expect(use.name, 'bash');
      expect(use.input, isEmpty);
      expect(use.argumentsParseError, contains('Unterminated string'),
          reason: 'the parse error rides on the block for the agent to relay');
    });

    test('a well-formed quote-heavy command still decodes (tin-p2sq)',
        () async {
      // The same one-liner, correctly escaped by the model: nested single and
      // double quotes plus backslash-escaped quotes must round-trip into the
      // tool input verbatim.
      const command =
          r'for f in *; do echo "file: $f"; done; echo "done: \"$?\""';
      final sse = [
        'data: ${jsonEncode({
              "choices": [
                {
                  "index": 0,
                  "delta": {
                    "tool_calls": [
                      {
                        "index": 0,
                        "id": "call_1",
                        "function": {
                          "name": "bash",
                          "arguments": jsonEncode({'command': command})
                        }
                      }
                    ]
                  }
                }
              ]
            })}',
        'data: ${jsonEncode({
              "choices": [
                {"index": 0, "delta": {}, "finish_reason": "tool_calls"}
              ]
            })}',
        'data: [DONE]',
        '',
      ].join('\n');
      final provider = OpenAiCompatibleAdapter(
          apiKey: 'k', model: 'm', client: ScriptedSseClient(sse));
      final events = await provider
          .send(system: '', messages: const [], tools: const [])
          .toList();

      final use = events
          .whereType<MessageComplete>()
          .single
          .content
          .whereType<ToolUseBlock>()
          .single;
      expect(use.argumentsParseError, isNull);
      expect(use.input['command'], command);
    });

    // #24: a stream that goes silent mid-response must name its own knob —
    // previously it surfaced as the same anonymous 'Request timed out' as the
    // request timeout, so the operator raised --request-timeout and nothing
    // changed.
    test('a stream that goes silent names --stream-idle-timeout', () async {
      final provider = OpenAiCompatibleAdapter(
        apiKey: 'k',
        model: 'm',
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
