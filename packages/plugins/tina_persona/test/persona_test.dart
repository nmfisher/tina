import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persona/tina_persona.dart';

void main() {
  test('the persona reaches the provider through the prompt phase', () async {
    final provider = ScriptedProvider([scriptedReply('hello')]);
    final loop =
        AgentLoop(provider: provider, plugins: [const PersonaPlugin()]);
    await loop.runTurn(const Input('hello', id: 't1'));
    expect(provider.requests.single.systemPrompt,
        contains('You are tina, a terminal coding agent.'));
  });
}
