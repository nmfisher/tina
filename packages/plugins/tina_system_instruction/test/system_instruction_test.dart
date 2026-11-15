import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_system_instruction/tina_system_instruction.dart';

void main() {
  test('the system instruction reaches the provider through the prompt phase',
      () async {
    final provider = ScriptedProvider([scriptedReply('hello')]);
    final loop = AgentLoop(
        provider: provider, plugins: [const SystemInstructionPlugin()]);
    await loop.runTurn(const Input('hello', id: 't1'));
    final prompt = provider.requests.single.systemPrompt;
    expect(prompt, startsWith('You are tina, a terminal coding agent.'));
    expect(prompt, contains('Be concise.'));
    expect(prompt, contains('plain, simple technical English'));
    expect(prompt, contains('Answer from what you already know'));
    expect(prompt, contains('as few tool calls as the work allows'));
  });

  test('commands stay direct and reusable shell logic uses scripts', () async {
    final provider = ScriptedProvider([scriptedReply('hello')]);
    final loop = AgentLoop(
        provider: provider, plugins: [const SystemInstructionPlugin()]);
    await loop.runTurn(const Input('hello', id: 't1'));
    final prompt = provider.requests.single.systemPrompt;
    expect(prompt, contains('Prefer exec with a program and literal args'));
    expect(prompt,
        contains('working_directory instead of prefixing commands with cd'));
    expect(prompt, contains('Short read-only pipelines'));
    expect(prompt, contains('substantial reusable multi-step logic'));
    expect(prompt, contains('prefer writing a script with the write tool'));
    expect(prompt, contains('running it with exec'));
    // The escape hatch keeps one-command inspection plain.
    expect(prompt, contains('Do not script what one command already answers'));
    // The stated reason is the stable approval target.
    expect(prompt, isNot(contains('an approval covers the rerun')));
  });
}
