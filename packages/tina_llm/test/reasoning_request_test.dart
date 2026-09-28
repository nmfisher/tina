import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';

void main() {
  test(
      'partial and unsigned reasoning remain local and never produce empty wire messages',
      () {
    final body =
        requestBody(model: 'test', system: '', tools: [], messages: const [
      Message(role: Role.user, content: [TextBlock('hello')]),
      Message(
          role: Role.assistant,
          content: [],
          reasoning: [ReasoningBlock('interrupted', complete: false)]),
      Message(role: Role.assistant, content: [
        TextBlock('answer')
      ], reasoning: [
        ReasoningBlock('old unsigned'),
        ReasoningBlock('partial signed', complete: false, signature: 'partial'),
        ReasoningBlock('complete signed', signature: 'valid'),
      ]),
    ]);
    final messages = body['messages'] as List;
    expect(messages, hasLength(2));
    expect(messages.last['content'], [
      {'type': 'thinking', 'thinking': 'complete signed', 'signature': 'valid'},
      {'type': 'text', 'text': 'answer'},
    ]);
  });
}
