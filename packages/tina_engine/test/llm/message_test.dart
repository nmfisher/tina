import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// Round-trip and parse tests for the provider-neutral content model. This is
/// the persisted session format, so a regression silently corrupts saved
/// conversations — every block type and the unknown-type guard are pinned.
void main() {
  group('ContentBlock JSON round-trip', () {
    test('TextBlock', () {
      const block = TextBlock('hello world');
      final json = block.toJson();
      expect(json, {'type': 'text', 'text': 'hello world'});
      final back = ContentBlock.fromJson(json) as TextBlock;
      expect(back.text, 'hello world');
    });

    test('ToolUseBlock preserves the input map', () {
      const block = ToolUseBlock(
        id: 'call_1',
        name: 'bash',
        input: {'command': 'ls -la', 'cwd': '/tmp'},
      );
      final json = block.toJson();
      expect(json, {
        'type': 'tool_use',
        'id': 'call_1',
        'name': 'bash',
        'input': {'command': 'ls -la', 'cwd': '/tmp'},
      });
      final back = ContentBlock.fromJson(json) as ToolUseBlock;
      expect(back.id, 'call_1');
      expect(back.name, 'bash');
      expect(back.input, {'command': 'ls -la', 'cwd': '/tmp'});
    });

    test('ToolResultBlock omits is_error when not an error', () {
      const block = ToolResultBlock(toolUseId: 'call_1', content: 'ok');
      final json = block.toJson();
      expect(json, {
        'type': 'tool_result',
        'tool_use_id': 'call_1',
        'content': 'ok',
      });
      expect(json.containsKey('is_error'), isFalse);
      final back = ContentBlock.fromJson(json) as ToolResultBlock;
      expect(back.isError, isFalse);
      expect(back.content, 'ok');
    });

    test('ToolResultBlock sets is_error when true', () {
      const block = ToolResultBlock(
        toolUseId: 'call_1',
        content: 'boom',
        isError: true,
      );
      final json = block.toJson();
      expect(json['is_error'], true);
      final back = ContentBlock.fromJson(json) as ToolResultBlock;
      expect(back.isError, isTrue);
      expect(back.content, 'boom');
    });
  });

  group('ContentBlock.fromJson', () {
    test('throws FormatException on an unknown block type', () {
      expect(
        () => ContentBlock.fromJson({'type': 'image', 'url': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException when type is missing', () {
      expect(
        () => ContentBlock.fromJson({'text': 'no type'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Message JSON round-trip', () {
    test('user message with mixed blocks survives a cycle', () {
      final msg = Message(role: Role.user, content: const [
        TextBlock('list files'),
        ToolResultBlock(toolUseId: 'call_1', content: 'file.txt'),
      ]);
      final back = Message.fromJson(msg.toJson());
      expect(back.role, Role.user);
      expect(back.content, hasLength(2));
      expect((back.content[0] as TextBlock).text, 'list files');
      final result = back.content[1] as ToolResultBlock;
      expect(result.toolUseId, 'call_1');
      expect(result.content, 'file.txt');
    });

    test('assistant message with a tool_use survives a JSON-string cycle', () {
      // Encode through a JSON string to mimic on-disk serialization exactly.
      final msg = Message(role: Role.assistant, content: const [
        TextBlock('running it'),
        ToolUseBlock(id: 'call_1', name: 'bash', input: {'command': 'ls'}),
      ]);
      final back = Message.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(msg.toJson())) as Map),
      );
      expect(back.role, Role.assistant);
      expect((back.content[0] as TextBlock).text, 'running it');
      final use = back.content[1] as ToolUseBlock;
      expect(use.id, 'call_1');
      expect(use.name, 'bash');
      expect(use.input, {'command': 'ls'});
    });
  });
}
