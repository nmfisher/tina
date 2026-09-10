import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// A [PromptContributor] recording that it contributed, so tests can assert
/// section order and membership.
class _TaggedContributor implements PromptContributor {
  @override
  final String id;

  final String text;

  _TaggedContributor(this.id, this.text);

  @override
  String contribute() => text;
}

void main() {
  group('defaultPromptContributors', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_prompt_contrib_');
      File('${tmp.path}/AGENTS.md').writeAsStringSync('# rules\n');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('plain context yields [identity, environment, project_context]', () {
      final contributors = defaultPromptContributors(
        identity: 'IDENTITY',
        context: PromptContext(projectRoot: tmp.path),
      );
      expect(contributors.map((c) => c.id),
          ['identity', 'environment', 'project_context']);
    });

    test('safeMode yields [safe_mode, identity, environment, project_context]',
        () {
      final contributors = defaultPromptContributors(
        identity: 'IDENTITY',
        context: PromptContext(projectRoot: tmp.path),
        safeMode: true,
      );
      expect(
        contributors.map((c) => c.id),
        ['safe_mode', 'identity', 'environment', 'project_context'],
      );
    });

    test('a context without AGENTS.md carries no project_context section', () {
      final empty = Directory.systemTemp.createTempSync('tina_no_agents_');
      addTearDown(() => empty.deleteSync(recursive: true));
      final contributors = defaultPromptContributors(
        identity: 'IDENTITY',
        context: PromptContext(projectRoot: empty.path),
      );
      expect(contributors.map((c) => c.id), ['identity', 'environment']);
    });

    test('loadProjectContext: false drops the project_context section', () {
      final contributors = defaultPromptContributors(
        identity: 'IDENTITY',
        context: PromptContext(projectRoot: tmp.path),
        loadProjectContext: false,
      );
      expect(contributors.map((c) => c.id), ['identity', 'environment']);
    });
  });

  group('joinPromptContributors vs _buildAgentPrompt output', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_prompt_join_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('byte-identical with repo summary + AGENTS.md (plain)', () {
      File('${tmp.path}/AGENTS.md').writeAsStringSync('# project rules\n');
      final pipeline = AgentPipeline(
        mainIdentity: 'JOIN-IDENTITY',
        promptContext: PromptContext(
          projectRoot: tmp.path,
          repoSummarySource: () => '<repo>\nbranch: main @ abc1234\n</repo>',
        ),
      );
      final resolved = resolveMainPrompt(pipeline, cwd: tmp.path);
      final joined = joinPromptContributors(defaultPromptContributors(
        identity: 'JOIN-IDENTITY',
        context: pipeline.promptContext,
        cwd: tmp.path,
      ));
      expect(joined, equals(resolved));
    });

    test('byte-identical under safeMode', () {
      File('${tmp.path}/AGENTS.md').writeAsStringSync('# rules\n- fmt\n');
      final pipeline = AgentPipeline(
        mainIdentity: 'JOIN-IDENTITY',
        promptContext: PromptContext(
          projectRoot: tmp.path,
          projectEnvironmentSource: () =>
              '<project-environment>\ntoolchain: Dart\n</project-environment>',
        ),
      );
      final resolved =
          resolveMainPrompt(pipeline, cwd: tmp.path, safeMode: true);
      final joined = joinPromptContributors(defaultPromptContributors(
        identity: 'JOIN-IDENTITY',
        context: pipeline.promptContext,
        cwd: tmp.path,
        safeMode: true,
      ));
      expect(joined, equals(resolved));
    });

    test('byte-identical when no AGENTS.md exists (no trailing newline gap)',
        () {
      final pipeline = AgentPipeline(
        mainIdentity: 'JOIN-IDENTITY',
        promptContext: PromptContext(projectRoot: tmp.path),
      );
      final resolved = resolveMainPrompt(pipeline, cwd: tmp.path);
      final joined = joinPromptContributors(defaultPromptContributors(
        identity: 'JOIN-IDENTITY',
        context: pipeline.promptContext,
        cwd: tmp.path,
      ));
      expect(joined, equals(resolved));
      expect(resolved, endsWith('</environment>\n'));
    });
  });

  group('promptContributorsFromScope', () {
    test('returns contributions in declared registration order', () async {
      final runtime = PluginRuntime(name: 'prompt-contributor-test', plugins: [
        promptContributorPlugin(
            'extra_a', _TaggedContributor('extra_a', 'SECTION A')),
        promptContributorPlugin(
            'extra_b', _TaggedContributor('extra_b', 'SECTION B')),
        promptContributorPlugin(
            'extra_c', _TaggedContributor('extra_c', 'SECTION C')),
      ]);
      await runtime.activate();
      final contributors = promptContributorsFromScope(runtime.scope);
      expect(contributors.map((c) => c.id), ['extra_a', 'extra_b', 'extra_c']);
      expect(contributors.map((c) => c.contribute()),
          ['SECTION A', 'SECTION B', 'SECTION C']);
    });

    test('ignores contributions that are not PromptContributors', () async {
      final runtime = PluginRuntime(name: 'prompt-contributor-test', plugins: [
        PluginDescriptor(
          id: 'other',
          factory: FnPluginFactory((context) {
            context.register('a string contribution', id: 'string-thing');
            return 'root';
          }),
        ),
        promptContributorPlugin(
            'extra_a', _TaggedContributor('extra_a', 'SECTION A')),
      ]);
      await runtime.activate();
      final contributors = promptContributorsFromScope(runtime.scope);
      expect(contributors.map((c) => c.id), ['extra_a']);
    });
  });

  group('promptContributorServiceKey', () {
    test('carries the documented seam id', () {
      expect(promptContributorServiceKey.id, 'tina.engine.prompt_contributor');
    });
  });

  group('throwing contributor containment', () {
    test('a throwing repo summary source still yields a prompt', () {
      final tmp = Directory.systemTemp.createTempSync('tina_prompt_throw_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pipeline = AgentPipeline(
        mainIdentity: 'THROW-IDENTITY',
        promptContext: PromptContext(
          projectRoot: tmp.path,
          repoSummarySource: () => throw StateError('boom'),
        ),
      );
      final s = resolveMainPrompt(pipeline, cwd: tmp.path);
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
      expect(s, contains('THROW-IDENTITY'));
    });
  });
}
