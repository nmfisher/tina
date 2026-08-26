import 'package:tina_engine/tina_engine.dart';
import 'package:tina/session_commands/session_export.dart';
import 'package:test/test.dart';

void main() {
  group('renderSessionTranscript', () {
    ConversationMeta conv(String id,
        {String label = '',
        ConversationKind kind = ConversationKind.primary,
        String? parent}) =>
        ConversationMeta(
            id: id, label: label, kind: kind, parentConversationId: parent);

    SessionManifest manifest(List<ConversationMeta> conversations,
        {String active = 'c1', String? baseUrl}) =>
        SessionManifest(
          id: 'sess-1',
          providerId: 'anthropic',
          baseUrl: baseUrl,
          activeConversationId: active,
          conversations: conversations,
        );

    test('renders header, one section per conversation, and a trailing newline',
        () {
      final m = manifest([conv('c1', label: 'test-model')]);
      final out = renderSessionTranscript(m, {
        'c1': [
          Message(role: Role.user, content: [TextBlock('hello world')]),
          Message(role: Role.assistant, content: [TextBlock('hi there')]),
        ],
      });

      expect(out, startsWith('# Session transcript — sess-1\n'));
      expect(out, contains('> hello world\n'));
      expect(out, contains('- provider: anthropic\n'));
      expect(out, contains('- conversations: 1, messages: 2\n'));
      expect(out, contains('- active conversation: c1\n'));
      expect(out, contains('## test-model — primary\n'));
      expect(out, contains('### user\n\nhello world\n'));
      expect(out, contains('### assistant\n\nhi there\n'));
      expect(out, endsWith('\n'));
    });

    test('is deterministic across calls', () {
      final m = manifest([conv('c1')]);
      final messages = [
        Message(role: Role.user, content: [TextBlock('a')]),
        Message(role: Role.assistant, content: [TextBlock('b')]),
      ];
      expect(renderSessionTranscript(m, {'c1': messages}),
          renderSessionTranscript(m, {'c1': messages}));
    });

    test('lists conversations in manifest order with kind and parent', () {
      final m = manifest([
        conv('c1', label: 'main'),
        conv('c2', label: 'helper', kind: ConversationKind.subAgent, parent: 'c1'),
      ]);
      final out = renderSessionTranscript(m, {
        'c1': [Message(role: Role.user, content: [TextBlock('x')])],
        'c2': [Message(role: Role.user, content: [TextBlock('y')])],
      });
      expect(out, contains('## main — primary\n'));
      expect(out, contains('## helper — subAgent, parent: c1\n'));
      // Manifest order is preserved, not map order.
      expect(out.indexOf('## main'), lessThan(out.indexOf('## helper')));
    });

    test('unlabeled conversations fall back to their id', () {
      final m = manifest([conv('c7')]);
      final out = renderSessionTranscript(m, {
        'c7': [Message(role: Role.user, content: [TextBlock('x')])],
      });
      expect(out, contains('## c7 — primary\n'));
    });

    test('marks an empty conversation and counts it as zero messages', () {
      final m = manifest([conv('c1'), conv('c2')]);
      final out = renderSessionTranscript(m, {
        'c1': [Message(role: Role.user, content: [TextBlock('x')])],
        'c2': [],
      });
      expect(out, contains('_(no messages)_\n'));
      expect(out, contains('- conversations: 2, messages: 1\n'));
    });

    test('renders a tool call as a one-line summary from its common keys', () {
      final m = manifest([conv('c1')]);
      final out = renderSessionTranscript(m, {
        'c1': [
          Message(
              role: Role.assistant,
              content: [
                ToolUseBlock(
                    id: 'tu1',
                    name: 'bash',
                    input: {'command': 'ls -la', 'extra': 'ignored'}),
                ToolUseBlock(id: 'tu2', name: 'grep', input: {'pattern': 'foo'}),
                ToolUseBlock(id: 'tu3', name: 'read', input: {
                  'filePath': '/etc/hosts'
                }),
                ToolUseBlock(id: 'tu4', name: 'custom', input: {}),
              ]),
        ],
      });
      expect(out, contains('→ tool: bash — ls -la\n'));
      expect(out, contains('→ tool: grep — foo\n'));
      expect(out, contains('→ tool: read — /etc/hosts\n'));
      expect(out, contains('→ tool: custom\n'));
    });

    test('flags a tool call whose arguments failed to parse', () {
      final m = manifest([conv('c1')]);
      final out = renderSessionTranscript(m, {
        'c1': [
          Message(
              role: Role.assistant,
              content: [
                ToolUseBlock(
                    id: 'tu1',
                    name: 'bash',
                    input: {},
                    argumentsParseError: 'bad json'),
              ]),
        ],
      });
      expect(out, contains('→ tool: bash — argument parse error\n'));
    });

    test('renders a tool result verbatim inside a fence', () {
      final body = 'line one\nline two with "quotes" and `backticks`';
      final m = manifest([conv('c1')]);
      final out = renderSessionTranscript(m, {
        'c1': [
          Message(
              role: Role.user,
              content: [
                ToolResultBlock(toolUseId: 'tu1', content: body),
                ToolResultBlock(
                    toolUseId: 'tu2', content: 'boom', isError: true),
              ]),
        ],
      });
      expect(out, contains('```\ntool result:\n$body\n```\n'));
      expect(out, contains('```\ntool result (error):\nboom\n```\n'));
    });

    test('a tool result containing a triple backtick gets a longer fence', () {
      // The model's own markdown (code fences) rides inside tool results —
      // a fixed ``` fence would close early and corrupt the transcript.
      final body = 'before\n```\ncode inside the result\n```\nafter';
      final m = manifest([conv('c1')]);
      final out = renderSessionTranscript(m, {
        'c1': [
          Message(role: Role.user,
              content: [ToolResultBlock(toolUseId: 'tu1', content: body)]),
        ],
      });
      expect(out, contains('````\ntool result:\n$body\n````\n'));
      // The body itself stays verbatim, fences included.
      expect(out, contains(body));
    });

    test('includes the base URL in the header when present', () {
      final m = manifest([conv('c1')], baseUrl: 'https://api.example.com');
      final out = renderSessionTranscript(m, {
        'c1': [Message(role: Role.user, content: [TextBlock('x')])],
      });
      expect(out, contains('- provider: anthropic (`https://api.example.com`)\n'));
    });

    test('derives the title from the first user text and truncates it', () {
      final long = 'x' * 81;
      final m = manifest([conv('c1')]);
      final out = renderSessionTranscript(m, {
        'c1': [
          Message(role: Role.assistant, content: [TextBlock('earlier reply')]),
          Message(role: Role.user, content: [TextBlock(long)]),
        ],
      });
      // Title = first USER text (the assistant's earlier reply is skipped),
      // truncated to 80 chars with an ellipsis.
      expect(out, contains('> ${'x' * 80}…\n'));
      expect(out, isNot(contains('> earlier reply\n')),
          reason: 'an assistant reply must not become the title');

      // No user text at all → no title line.
      final out2 = renderSessionTranscript(m, {
        'c1': [Message(role: Role.assistant, content: [TextBlock('solo')])],
      });
      expect(out2, isNot(contains('> solo')));
    });

    test('conversation ids absent from the map render as empty, not missing',
        () {
      final m = manifest([conv('c1'), conv('c2')]);
      // Only c1 was loaded; c2 has no entry (e.g. unreadable file).
      final out = renderSessionTranscript(m, {
        'c1': [Message(role: Role.user, content: [TextBlock('x')])],
      });
      expect(out, contains('## c2 — primary\n\n_(no messages)_\n'));
    });
  });
}