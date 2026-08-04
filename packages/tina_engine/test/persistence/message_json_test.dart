import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('ContentBlock JSON', () {
    test('TextBlock round-trips', () {
      const b = TextBlock('hello\nworld');
      final j = b.toJson();
      expect(j, {'type': 'text', 'text': 'hello\nworld'});
      final r = ContentBlock.fromJson(j) as TextBlock;
      expect(r.text, b.text);
    });

    test('ToolUseBlock round-trips and preserves input shape', () {
      const b = ToolUseBlock(id: 'u1', name: 'read', input: {
        'filePath': '/tmp/x',
        'limit': 100,
        'nested': {'a': 1, 'b': true},
      });
      final j = b.toJson();
      expect(j['type'], 'tool_use');
      expect(j['id'], 'u1');
      expect(j['name'], 'read');
      final r = ContentBlock.fromJson(jsonDecode(jsonEncode(j))
          as Map<String, dynamic>) as ToolUseBlock;
      expect(r.id, b.id);
      expect(r.name, b.name);
      expect(r.input['filePath'], '/tmp/x');
      expect(r.input['limit'], 100);
      expect(r.input['nested'], {'a': 1, 'b': true});
    });

    test('ToolResultBlock round-trips; is_error omitted when false', () {
      const ok = ToolResultBlock(toolUseId: 'u1', content: 'done');
      expect(ok.toJson().containsKey('is_error'), isFalse);
      final rOk =
          ContentBlock.fromJson(ok.toJson()) as ToolResultBlock;
      expect(rOk.isError, isFalse);
      expect(rOk.toolUseId, 'u1');
      expect(rOk.content, 'done');

      const bad = ToolResultBlock(
          toolUseId: 'u2', content: 'boom', isError: true);
      expect(bad.toJson()['is_error'], isTrue);
      final rBad =
          ContentBlock.fromJson(bad.toJson()) as ToolResultBlock;
      expect(rBad.isError, isTrue);
    });

    test('unknown type throws FormatException', () {
      expect(
        () => ContentBlock.fromJson(const {'type': 'mystery'}),
        throwsFormatException,
      );
    });
  });

  group('Message JSON', () {
    test('round-trips mixed content', () {
      final m = Message(role: Role.assistant, content: [
        const TextBlock('I will read it.'),
        const ToolUseBlock(id: 'u1', name: 'read', input: {
          'filePath': '/tmp/x.txt',
        }),
      ]);
      final encoded = jsonEncode(m.toJson());
      final decoded = Message.fromJson(
          jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded.role, Role.assistant);
      expect(decoded.content, hasLength(2));
      expect(decoded.content[0], isA<TextBlock>());
      expect((decoded.content[0] as TextBlock).text, 'I will read it.');
      expect(decoded.content[1], isA<ToolUseBlock>());
      expect((decoded.content[1] as ToolUseBlock).input['filePath'],
          '/tmp/x.txt');
    });

    test('user message with tool_result round-trips', () {
      final m = Message(role: Role.user, content: const [
        ToolResultBlock(toolUseId: 'u1', content: 'file body…'),
      ]);
      final r = Message.fromJson(
          jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(r.role, Role.user);
      final tr = r.content.single as ToolResultBlock;
      expect(tr.toolUseId, 'u1');
      expect(tr.content, 'file body…');
    });
  });
}
