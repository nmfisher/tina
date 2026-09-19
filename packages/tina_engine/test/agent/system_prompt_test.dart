import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('resolveMainPrompt', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('returns the identity + environment block when no AGENTS.md exists',
        () {
      final s = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(s, contains('coding assistant'));
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
      expect(s, isNot(contains('<project-context>')));
    });

    test('injects AGENTS.md content found in cwd', () {
      File('${tmp.path}/AGENTS.md')
          .writeAsStringSync('# project rules\n- always run dart format\n');
      final s = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(s, contains('<project-context>'));
      expect(s, contains('always run dart format'));
      expect(s, contains('AGENTS.md'));
    });

    test('concatenates outer and inner AGENTS.md, inner last', () {
      final inner = Directory('${tmp.path}/sub')..createSync();
      File('${tmp.path}/AGENTS.md').writeAsStringSync('OUTER RULE\n');
      File('${inner.path}/AGENTS.md').writeAsStringSync('INNER RULE\n');
      final s = resolveMainPrompt(defaultPipeline, cwd: inner.path);
      final outerIdx = s.indexOf('OUTER RULE');
      final innerIdx = s.indexOf('INNER RULE');
      expect(outerIdx, isNonNegative);
      expect(innerIdx, isNonNegative);
      expect(outerIdx, lessThan(innerIdx),
          reason: 'innermost AGENTS.md should win — render it last');
    });
  });

  group('resolveMainPrompt overrides', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_resolveprompt_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('uses the [prompts.main] override when one is set', () {
      const identity = 'You are a totally bespoke agent. Squawk like a parrot.';
      final s = resolveMainPrompt(
        defaultPipeline,
        overrides: {'main': identity},
        cwd: tmp.path,
      );
      expect(s, contains(identity));
      expect(s, isNot(contains('coding assistant')));
      // The wrapper still applies on top of the override.
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
    });

    test('an empty override falls back to the main identity', () {
      final withEmpty = resolveMainPrompt(
        defaultPipeline,
        overrides: {'main': ''},
        cwd: tmp.path,
      );
      final withNone = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(withEmpty, equals(withNone));
      expect(withEmpty, contains('coding assistant'));
    });

    test('the override only replaces identity; the AGENTS.md wrapper survives',
        () {
      File('${tmp.path}/AGENTS.md').writeAsStringSync('PROJECT RULE\n');
      const identity = 'Custom identity with no AGENTS mention.';
      final s = resolveMainPrompt(
        defaultPipeline,
        overrides: {'main': identity},
        cwd: tmp.path,
      );
      expect(s, contains('PROJECT RULE'));
      expect(s, contains('<project-context>'));
    });
  });

  group('resolveMainPrompt safe-mode', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_safe_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('prepends the <safe-mode> block when safeMode is true', () {
      final s =
          resolveMainPrompt(defaultPipeline, cwd: tmp.path, safeMode: true);
      expect(s, contains('<safe-mode>'));
      expect(s, contains('READ-ONLY'));
      expect(s, contains('write, edit'));
      expect(s, contains('</safe-mode>'));
      // The preamble leads the identity.
      expect(s.indexOf('<safe-mode>'), lessThan(s.indexOf('coding assistant')));
    });

    test('omits the preamble when safeMode is false (default)', () {
      final s = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(s, isNot(contains('<safe-mode>')));
    });

    test('preamble survives an override identity', () {
      final s = resolveMainPrompt(
        defaultPipeline,
        overrides: {'main': 'Custom identity.'},
        cwd: tmp.path,
        safeMode: true,
      );
      expect(s, contains('<safe-mode>'));
      expect(s, contains('Custom identity.'));
    });
  });

  group('resolveMainPrompt project-trust gating', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_trust_');
      File('${tmp.path}/AGENTS.md')
          .writeAsStringSync('UNTRUSTED PROJECT RULE\n');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('withholds AGENTS.md when loadProjectContext is false', () {
      final s = resolveMainPrompt(defaultPipeline,
          cwd: tmp.path, loadProjectContext: false);
      expect(s, isNot(contains('<project-context>')));
      expect(s, isNot(contains('UNTRUSTED PROJECT RULE')));
      // Identity + environment still present.
      expect(s, contains('coding assistant'));
      expect(s, contains('<environment>'));
    });

    test('loads AGENTS.md when loadProjectContext is true (default)', () {
      final s = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(s, contains('<project-context>'));
      expect(s, contains('UNTRUSTED PROJECT RULE'));
    });
  });

  group('defaultPipeline main identity', () {
    test('carries a non-empty identity, sans wrapper', () {
      expect(defaultPipeline.mainIdentity, isNotEmpty);
      expect(defaultPipeline.mainIdentity, isNot(contains('<environment>')));
      expect(
          defaultPipeline.mainIdentity, isNot(contains('<project-context>')));
    });

    test('the identity carries its distinctive marker', () {
      expect(defaultPipeline.mainIdentity, contains('coding assistant'));
    });
  });

  group('projectEnvironmentSource hook', () {
    late Directory tmp;
    String? Function()? projectEnvironmentSource;
    String? Function()? repoSummarySource;

    AgentPipeline pipeline() => AgentPipeline(
          mainIdentity: defaultPipeline.mainIdentity,
          promptContext: PromptContext(
            projectRoot: tmp.path,
            projectEnvironmentSource: projectEnvironmentSource,
            repoSummarySource: repoSummarySource,
          ),
        );

    setUp(() {
      projectEnvironmentSource = null;
      repoSummarySource = null;
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_env_');
    });

    tearDown(() {
      projectEnvironmentSource = null;
      tmp.deleteSync(recursive: true);
    });

    test('injects the block inside <environment> when the hook is set', () {
      projectEnvironmentSource = () =>
          '<project-environment>\ntoolchain: Dart\n</project-environment>';
      final s = resolveMainPrompt(pipeline(), cwd: tmp.path);
      expect(s, contains('<project-environment>'));
      expect(s, contains('toolchain: Dart'));
      // The block rides inside the environment funnel, after the date line.
      expect(s.indexOf('date:'), lessThan(s.indexOf('<project-environment>')));
    });

    test('withholds the block when loadProjectContext is false', () {
      projectEnvironmentSource = () => 'LEAKED ENVIRONMENT';
      final s = resolveMainPrompt(pipeline(),
          cwd: tmp.path, loadProjectContext: false);
      expect(s, isNot(contains('LEAKED ENVIRONMENT')));
    });

    test('a throwing source cannot break prompt assembly', () {
      projectEnvironmentSource = () => throw StateError('boom');
      final s = resolveMainPrompt(pipeline(), cwd: tmp.path);
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
    });

    test('no hook (default): byte-identical output to a null source', () {
      projectEnvironmentSource = null;
      final a = resolveMainPrompt(pipeline(), cwd: tmp.path);
      final b = resolveMainPrompt(pipeline(), cwd: tmp.path);
      expect(a, equals(b));
      expect(a, isNot(contains('<project-environment>')));
    });
  });

  group('repoSummarySource hook', () {
    late Directory tmp;
    String? Function()? projectEnvironmentSource;
    String? Function()? repoSummarySource;

    AgentPipeline pipeline() => AgentPipeline(
          mainIdentity: defaultPipeline.mainIdentity,
          promptContext: PromptContext(
            projectRoot: tmp.path,
            projectEnvironmentSource: projectEnvironmentSource,
            repoSummarySource: repoSummarySource,
          ),
        );

    setUp(() {
      projectEnvironmentSource = null;
      repoSummarySource = null;
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_repo_');
    });

    tearDown(() {
      repoSummarySource = null;
      tmp.deleteSync(recursive: true);
    });

    test(
        'injects the block inside <environment>, before any '
        '<project-environment>', () {
      repoSummarySource = () => '<repo>\nbranch: main @ abc1234\n</repo>';
      projectEnvironmentSource = () =>
          '<project-environment>\ntoolchain: Dart\n</project-environment>';
      addTearDown(() => projectEnvironmentSource = null);
      final s = resolveMainPrompt(pipeline(), cwd: tmp.path);
      expect(s, contains('<repo>'));
      expect(s, contains('branch: main @ abc1234'));
      expect(s.indexOf('date:'), lessThan(s.indexOf('<repo>')));
      expect(s.indexOf('<repo>'), lessThan(s.indexOf('<project-environment>')));
    });

    test('withholds the block when loadProjectContext is false', () {
      repoSummarySource = () => 'LEAKED REPO SUMMARY';
      final s = resolveMainPrompt(pipeline(),
          cwd: tmp.path, loadProjectContext: false);
      expect(s, isNot(contains('LEAKED REPO SUMMARY')));
    });

    test('a throwing source cannot break prompt assembly', () {
      repoSummarySource = () => throw StateError('boom');
      final s = resolveMainPrompt(pipeline(), cwd: tmp.path);
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
    });
  });

  group('resolveIdentityPrompt (node identity)', () {
    test('wraps a bare identity with the environment block', () {
      final s = resolveIdentityPrompt('NODE-IDENTITY');
      expect(s, contains('NODE-IDENTITY'));
      expect(s, contains('<environment>'));
    });
  });

  group('workflow guidance (RuntimeConfig.enableWorkflow)', () {
    test('the shipped identity advertises the workflow path', () {
      expect(defaultPipeline.mainIdentity, contains('launch_workflow'));
      expect(defaultPipeline.mainIdentity, contains('stop_workflow'));
    });

    test('stripping leaves an identity that mentions no workflow at all', () {
      // The strong invariant: an agent without the launch_workflow tool must
      // not be told about workflows anywhere — not the bullet, not the
      // sub-agent aside, not the delegate bullet, not read-all's list.
      final stripped = stripWorkflowGuidance(defaultPipeline.mainIdentity);
      expect(stripped, isNot(contains('workflow')));
      expect(stripped, isNot(contains('launch_workflow')));
      expect(stripped, isNot(contains('stop_workflow')));
      // Everything else survives intact.
      expect(stripped, contains('You have these ways to act:'));
      expect(stripped, contains('For a small, well-scoped change'));
      expect(stripped, contains('Delegate a single focused sub-task'));
      expect(stripped, contains('Ask the user when a decision is genuinely'));
      expect(stripped, contains('launched as a sub-agent'));
      expect(stripped, contains('A failure unrelated to your change'));
      // No stray blank line or orphaned list marker where the bullet was.
      expect(stripped, contains('You have these ways to act:\n\n- For a small'));
    });

    test('stripping is a no-op on an identity with no workflow guidance', () {
      const custom = 'You are a bespoke agent. Carry out the task.';
      expect(stripWorkflowGuidance(custom), custom);
    });

    test('resolveMainPrompt drops the guidance when the surface is off', () {
      final on = resolveMainPrompt(defaultPipeline);
      final off = resolveMainPrompt(defaultPipeline, workflowEnabled: false);
      expect(on, contains('launch_workflow'));
      // The wrapped prompt carries the project's AGENTS.md as well, which is
      // free to talk about workflows; what must be gone is the workflow
      // *tooling* guidance.
      expect(off, isNot(contains('launch_workflow')));
      expect(off, isNot(contains('stop_workflow')));
      expect(off, contains('You have these ways to act:'));
    });

    test("a [prompts.main] override is the user's prose, never rewritten", () {
      final s = resolveMainPrompt(
        defaultPipeline,
        overrides: const {'main': 'MY OWN IDENTITY'},
        workflowEnabled: false,
      );
      expect(s, contains('MY OWN IDENTITY'));
      expect(s, isNot(contains('You have these ways to act')));
    });
  });
  group('PromptContext — per-pipeline state and renderers', () {
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
  });
}
