import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  test('interleaved prompts retain root, trust and fresh source reads', () {
    final temp = Directory.systemTemp.createTempSync('prompt-context-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final a = Directory('${temp.path}/a')..createSync();
    final b = Directory('${temp.path}/b')..createSync();
    File('${a.path}/AGENTS.md').writeAsStringSync('A instructions');
    File('${b.path}/AGENTS.md').writeAsStringSync('B instructions');
    var revision = 1;
    final first = AgentPipeline(
        promptContext: PromptContext(
      projectRoot: a.path,
      repoSummarySource: () => 'A repo $revision',
      projectEnvironmentSource: () => 'A environment $revision',
    ));
    var untrustedReads = 0;
    final second = AgentPipeline(
        promptContext: PromptContext(
      projectRoot: b.path,
      loadProjectContext: false,
      repoSummarySource: () {
        untrustedReads++;
        return 'B repo';
      },
    ));
    expect(resolveMainPrompt(first), contains('A repo 1'));
    for (final prompt in [
      resolveMainPrompt(second, loadProjectContext: true),
      resolveIdentityPrompt('node',
          context: second.promptContext, loadProjectContext: true)
    ]) {
      expect(prompt, contains('cwd: ${b.path}'));
      expect(prompt, isNot(contains('B instructions')));
      expect(prompt, isNot(contains('B repo')));
      expect(prompt, isNot(contains('A environment')));
    }
    expect(untrustedReads, 0);
    revision = 2;
    File('${a.path}/AGENTS.md').writeAsStringSync('A revised');
    for (final prompt in [
      resolveMainPrompt(first),
      resolveIdentityPrompt('node', context: first.promptContext)
    ]) {
      expect(prompt, contains('cwd: ${a.path}'));
      expect(prompt, contains('A revised'));
      expect(prompt, contains('A repo 2'));
      expect(prompt, contains('A environment 2'));
      expect(prompt, isNot(contains('B instructions')));
    }
  });

  test('renderers belong to the pipeline and can be detached independently',
      () async {
    final a = AgentPipeline();
    final b = AgentPipeline();
    final paths = <String>[];
    a.imageRenderer.coordinate((path) async {
      paths.add('A:$path');
      return null;
    });
    b.imageRenderer.coordinate((path) async {
      paths.add('B:$path');
      return null;
    });
    final first = RenderTool(renderer: a.imageRenderer);
    final second = RenderTool(renderer: b.imageRenderer);
    await first.execute({'path': 'one.png'});
    await second.execute({'path': 'two.png'});
    b.imageRenderer.coordinate(null);
    expect((await second.execute({'path': 'three.png'})).isError, isTrue);
    await first.execute({'path': 'four.png'});
    expect(paths, ['A:one.png', 'B:two.png', 'A:four.png']);
  });
}
