import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';

void main() {
  const image = ImageBlock(data: 'aGVsbG8=', mimeType: 'image/png');
  const message = Message(role: Role.user, content: [
    ToolResultBlock(
        toolUseId: 'shot', content: 'Blender screenshot', images: [image]),
  ]);
  test('tool images survive transcript replay without changing legacy results',
      () {
    final restored = Message.fromJson(message.toJson());
    expect((restored.content.single as ToolResultBlock).images.single.data,
        image.data);
    const old = ToolResultBlock(toolUseId: 'old', content: 'text');
    expect(old.toJson(),
        {'type': 'tool_result', 'tool_use_id': 'old', 'content': 'text'});
  });
  test('Anthropic receives native image content inside tool results', () {
    final body =
        requestBody(model: 'test', system: '', messages: [message], tools: []);
    final block =
        ((body['messages'] as List).single['content'] as List).single as Map;
    expect(block.containsKey('images'), false);
    expect(block['content'], [
      {'type': 'text', 'text': 'Blender screenshot'},
      image.toJson(),
    ]);
  });
  test('OpenAI receives paired tool text followed by a multimodal user message',
      () {
    final wire = chatCompletionsMessages([message]);
    expect(wire.first, {
      'role': 'tool',
      'tool_call_id': 'shot',
      'content': 'Blender screenshot'
    });
    expect(wire.last['role'], 'user');
    expect((wire.last['content'] as List).last, {
      'type': 'image_url',
      'image_url': {'url': 'data:image/png;base64,aGVsbG8='},
    });
  });
  test('Gemini receives inline image data alongside its function response', () {
    final parts = geminiContents([message], {'shot': 'screenshot'})
        .single['parts'] as List;
    expect(parts.first['functionResponse']['name'], 'screenshot');
    expect(parts.last, {
      'inlineData': {'mimeType': 'image/png', 'data': 'aGVsbG8='}
    });
  });
}
