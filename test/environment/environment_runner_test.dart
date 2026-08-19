// End-to-end test for [EnvironmentRunner]: drives the real background
// environment agent (a doing worker on the ephemeral composition) against a
// stub [LlmProvider], and asserts the record lands at the repo root AND the
// machine-owned tracking entry is recorded by Dart after the finish — plus the
// registry-decorator restore the ephemeral pattern promises.
//
// Reuses the summary-fleet harness (temp committed project, scripted provider,
// registry/config wiring); `--yolo` pre-approves the agent's `write` so no
// interactive asker is needed.

import 'dart:io';

import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/environment/environment_index.dart';
import 'package:tina/environment/environment_runner.dart';
import 'package:tina/environment/environment_store.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_host_interface.dart';
import '../summaries/fleet_test_harness.dart';

/// Scripts the environment agent's turns:
///
///   1. `write` .tina/ENVIRONMENT.md in the sidecar (tool_use)
///   2. final report (end_turn)
///
/// With [writesRecord] false, turn 1 is prose only — an agent that answers
/// without ever invoking its write tool (the tin-h5nm false-success shape).
/// On a warm load the write carries an updated baseline so the record's
/// content actually changes.
class ScriptedEnvProvider extends LlmProvider {
  int callCount = 0;

  /// Calls from the first-load folder survey's scout agents (read-only —
  /// no `write` tool). They answer instantly and do NOT advance [callCount],
  /// so the main ceremony's script below is undisturbed by the fan-out.
  int surveyorCalls = 0;

  /// The last user-message text of every non-survey call, so tests can
  /// assert what the main agent was actually asked to do.
  final List<String> mainUserPrompts = [];

  final String projectPath;
  final bool writesRecord;

  ScriptedEnvProvider(this.projectPath, {this.writesRecord = true})
      : super('env');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    const usage = TokenUsage(inputTokens: 100, outputTokens: 50);
    // A scout (the folder survey) has no write tool: answer in prose at once.
    // Streamed as a delta + complete, like a real provider — the delta is
    // what reaches the scout's sink (its panel).
    if (!tools.any((t) => t.name == 'write')) {
      surveyorCalls++;
      const description = 'a small Dart package with library sources';
      yield const TextDelta(description);
      yield MessageComplete(
        content: const [TextBlock(description)],
        stopReason: 'end_turn',
        usage: usage,
      );
      return;
    }
    callCount++;
    final lastUser = messages.lastWhere((m) => m.role == Role.user);
    mainUserPrompts.add(lastUser.content
        .whereType<TextBlock>()
        .map((b) => b.text)
        .join());
    switch (callCount) {
      case 1:
        if (!writesRecord) {
          yield MessageComplete(
            content: const [
              TextBlock('environment looks fine; nothing needed writing'),
            ],
            stopReason: 'end_turn',
            usage: usage,
          );
          return;
        }
        final warm = File('$projectPath/.tina/ENVIRONMENT.md').existsSync();
        yield MessageComplete(
          content: [
            ToolUseBlock(
              id: 'w1',
              name: 'write',
              input: {
                'filePath': '$projectPath/.tina/ENVIRONMENT.md',
                'content': warm
                    ? '''
# Environment

## Toolchain
- Dart 3.9 (measured)

## Setup
- dart pub get

## Test baseline
- 3 tests, 0 failures (re-measured)
'''
                    : '''
# Environment

## Toolchain
- Dart 3.9 (measured)

## Setup
- dart pub get

## Test baseline
- 0 tests (measured)
''',
              },
            ),
          ],
          stopReason: 'tool_use',
          usage: usage,
        );
      default:
        yield MessageComplete(
          content: const [
            TextBlock('measured the toolchain, ran setup; record written'),
          ],
          stopReason: 'end_turn',
          usage: usage,
        );
    }
  }
}

/// Records streamed prose into [onText]; swallows everything else — the
/// survey-sink-factory test's stand-in for a scout's panel host.
class _RecordingSink implements AgentSink {
  final void Function(String s) onText;
  _RecordingSink(this.onText);
  @override
  void text(String s) => onText(s);
  @override
  void newline() {}
  @override
  void toolStart(ToolStartEvent event) {}
  @override
  void toolOutput(ToolOutputEvent event) {}
  @override
  void toolComplete(ToolCompleteEvent event) {}
  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {}
  @override
  void activityStart() {}
  @override
  void activityStop() {}
}

void main() {
  late Directory tempRoot;
  late Directory project;

  setUp(() {
    final t = buildTempProject();
    tempRoot = t.tempRoot;
    project = t.project;
    // The record's sidecar dir — tests and the agent's write tool both
    // expect `<project>/.tina/` to exist for ENVIRONMENT.md.
    Directory('${project.path}/.tina').createSync();
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('the agent writes the record; Dart records the tracking entry',
      () async {
    final provider = ScriptedEnvProvider(project.path);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );
    final runner = EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    );

    final ok = await runner.run().timeout(const Duration(seconds: 30));

    expect(ok, isTrue, reason: 'a finished run records the region');
    // The agent wrote the record through the ordinary sandboxed write tool.
    final record = File('${project.path}/.tina/ENVIRONMENT.md');
    expect(record.existsSync(), isTrue);
    expect(record.readAsStringSync(), contains('## Toolchain'));
    // Dart — not the agent — recorded the tracking entry, and the region now
    // reads current.
    final store = EnvironmentTrackingStore(projectRoot: project.path);
    expect(store.load(), isNotNull);
    expect(store.staleReason(), isNull);
  });

  test('a prose-only finish is not a success: region stays stale (tin-h5nm)',
      () async {
    final provider = ScriptedEnvProvider(project.path, writesRecord: false);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );

    final ok = await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    ).run().timeout(const Duration(seconds: 30));

    expect(ok, isFalse,
        reason: 'answering in prose must not read as a completed ceremony');
    // No record was written, and — the actual bug — the region was NOT
    // stamped fresh: the next launch re-runs the ceremony instead of
    // trusting a phantom update.
    expect(File('${project.path}/.tina/ENVIRONMENT.md').existsSync(), isFalse);
    final store = EnvironmentTrackingStore(projectRoot: project.path);
    expect(store.load(), isNull);
    expect(store.staleReason(), isNotNull);
  });

  test('a warm re-verify that leaves the record unchanged is not a success',
      () async {
    File('${project.path}/.tina/ENVIRONMENT.md').writeAsStringSync('''
## Build
- dart analyze
''');
    final provider = ScriptedEnvProvider(project.path, writesRecord: false);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );

    final ok = await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    ).run().timeout(const Duration(seconds: 30));

    expect(ok, isFalse, reason: 'no content change → no advance');
    expect(EnvironmentTrackingStore(projectRoot: project.path).load(), isNull);
  });

  test('a warm re-verify that rewrites the record is a success', () async {
    File('${project.path}/.tina/ENVIRONMENT.md').writeAsStringSync('''
## Build
- dart analyze
''');
    final provider = ScriptedEnvProvider(project.path);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );

    final ok = await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    ).run().timeout(const Duration(seconds: 30));

    expect(ok, isTrue, reason: 'the record content actually changed');
    final record = File('${project.path}/.tina/ENVIRONMENT.md');
    expect(record.readAsStringSync(), contains('3 tests, 0 failures'));
    expect(EnvironmentTrackingStore(projectRoot: project.path).staleReason(),
        isNull);
  });

  test('run() restores the registry decorator it temporarily mutates',
      () async {
    final provider = ScriptedEnvProvider(project.path);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );
    final before = registry.decorator;

    await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    ).run().timeout(const Duration(seconds: 30));

    expect(identical(registry.decorator, before), isTrue,
        reason: 'the ephemeral composition must not leak its decorator');
  });

  // A registry offering TWO providers, each serving its own scripted provider
  // instance — so which model the environment agent resolved to is observable
  // from which instance got called.
  ProviderRegistry twoProviderRegistry(
      LlmProvider anthropic, LlmProvider nim) {
    final r = ProviderRegistry(env: const {
      'TEST_KEY': 'k',
      'ANTHROPIC_API_KEY': 'k',
      'NVIDIA_API_KEY': 'k',
    });
    for (final (id, provider) in [('anthropic', anthropic), ('nim', nim)]) {
      r.register(ProviderDescriptor(
        id: id,
        name: id,
        authSources: const [
          AuthSource('TEST_KEY', AuthScheme.bearerToken),
        ],
        defaultBaseUrl: 'https://example.test',
        builder: (_) => provider,
        models: const {
          'a-model': ModelInfo(
              id: 'a-model', name: 'm', contextWindow: 1, maxOutput: 1),
        },
      ));
    }
    return r;
  }

  test('an explicit modelRef runs the agent on that model, not the startup one',
      () async {
    final startup = ScriptedEnvProvider(project.path);
    final envModel = ScriptedEnvProvider(project.path);
    final registry = twoProviderRegistry(startup, envModel);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );

    final ok = await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
      modelRef: 'nim/a-model',
    ).run().timeout(const Duration(seconds: 30));

    expect(ok, isTrue);
    expect(envModel.callCount, greaterThan(0),
        reason: 'the agent ran on the picked environment model');
    expect(startup.callCount, 0,
        reason: 'the startup provider must not serve the environment agent');
  });

  test('config.environmentModel picks the model when no explicit ref is given',
      () async {
    final startup = ScriptedEnvProvider(project.path);
    final envModel = ScriptedEnvProvider(project.path);
    final registry = twoProviderRegistry(startup, envModel);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
      userConfig:
          const UserConfig(environmentModel: 'nim/a-model'),
    );

    await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    ).run().timeout(const Duration(seconds: 30));

    expect(envModel.callCount, greaterThan(0));
    expect(startup.callCount, 0);
  });

  test('an unresolvable default ref falls back to the startup provider',
      () async {
    // anthropicRegistry offers no `nim` provider, so the shipped default
    // (nim/google/diffusiongemma-26b-a4b-it) cannot resolve — the run must
    // still proceed on the startup provider instead of failing.
    final provider = ScriptedEnvProvider(project.path);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );

    final ok = await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    ).run().timeout(const Duration(seconds: 30));

    expect(ok, isTrue);
    expect(provider.callCount, greaterThan(0),
        reason: 'the startup provider served the fallback');
  });

  test('the asker override reaches the agent permission gate (no --yolo)',
      () async {
    // Without --yolo, `write` is gated (ask). The default headless host
    // auto-denies, so the ceremony could never write the record; an asker
    // override (the TUI's attention-queue asker) must reach the gate.
    final provider = ScriptedEnvProvider(project.path);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );
    final asked = <String>[];
    final ok = await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
      asker: (prompt) async {
        asked.add(prompt.toolName);
        return PermissionResponse.allowOnce;
      },
    ).run().timeout(const Duration(seconds: 30));

    expect(ok, isTrue, reason: 'the allowed write records the region');
    expect(asked, contains('write'));
    expect(File('${project.path}/.tina/ENVIRONMENT.md').existsSync(), isTrue);
  });

  test('first load surveys the repo root and each top-level subfolder with '
      'read-only scouts', () async {
    // A third surveyable folder beyond the harness's `lib`.
    Directory('${project.path}/tooling').createSync();
    final provider = ScriptedEnvProvider(project.path);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );

    final ok = await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
    ).run().timeout(const Duration(seconds: 30));

    expect(ok, isTrue);
    // '.', 'lib', 'tooling' — hidden dirs (.tina) are not surveyed.
    expect(provider.surveyorCalls, 3);
    // The scouts' report rides into the main agent's task prompt.
    final prompt = provider.mainUserPrompts.first;
    expect(prompt, contains('<folder-survey>'));
    expect(prompt, contains('### repository root'));
    expect(prompt, contains('### lib'));
    expect(prompt, contains('### tooling'));
  });

  test('a scoutSinkFactory opens one sink per surveyed folder', () async {
    Directory('${project.path}/tooling').createSync();
    final provider = ScriptedEnvProvider(project.path);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );

    final openedDirs = <String>[];
    final textsByDir = <String, String>{};
    await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
      scoutSinkFactory: (dir) {
        openedDirs.add(dir);
        return _RecordingSink((s) => textsByDir[dir] =
            (textsByDir[dir] ?? '') + s);
      },
    ).run().timeout(const Duration(seconds: 30));

    // Root + lib + tooling, in target order.
    expect(openedDirs, ['.', 'lib', 'tooling']);
    // Each factory sink received its scout's streamed description.
    for (final dir in openedDirs) {
      expect(textsByDir[dir], contains('Dart package'),
          reason: 'scout for "$dir" streamed into its own sink');
    }
  });

  test('the ceremony drives the host activity signal for its whole run', () async {
    // The ceremony runs outside the session turn loop, so the env panel's
    // busy comet depends on the runner driving the host signal itself —
    // covering the folder survey too, not just the main agent turn (the
    // nested Agent.run raise/clear rides inside; hosts treat repeats as
    // idempotent). Part of the activity matrix pinned per path (tin-y4qn).
    Directory('${project.path}/tooling').createSync();
    final provider = ScriptedEnvProvider(project.path);
    final registry = anthropicRegistry(provider);
    final config = Config.parse(
      const ['--backend', 'ansi', '--yolo'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );
    final host = FakeHostInterface();
    var raisedBeforeFirstScout = false;
    final ok = await EnvironmentRunner(
      config: config,
      registry: registry,
      environment: const PlatformEnvironment(),
      projectRoot: project.path,
      host: host,
      scoutSinkFactory: (dir) {
        // The first scout starts only after the survey phase began — by
        // then the panel must already be lit.
        raisedBeforeFirstScout |= host.activitySignals.contains(true);
        return _RecordingSink((_) {});
      },
    ).run().timeout(const Duration(seconds: 30));

    expect(ok, isTrue);
    expect(raisedBeforeFirstScout, isTrue,
        reason: 'the busy cue is up during the survey phase, before the '
            'main agent turn');
    expect(host.activitySignals.first, isTrue);
    expect(host.activitySignals.last, isFalse,
        reason: 'the cue clears on every exit path — an idle panel must not '
            'animate');
  });

  test('projectEnvironmentBlock renders the record + machine status', () {
    // No record yet: nothing to warm-load.
    expect(projectEnvironmentBlock(project.path), isNull);

    // A record with no tracking entry: present but STALE (never measured).
    File('${project.path}/.tina/ENVIRONMENT.md').writeAsStringSync('''
## Build
- dart analyze
''');
    final stale = projectEnvironmentBlock(project.path)!;
    expect(stale, contains('<project-environment>'));
    expect(stale, contains('build: dart analyze'));
    expect(stale, contains('status: STALE — never measured'));

    // Measured: current.
    EnvironmentTrackingStore(projectRoot: project.path).record();
    final fresh = projectEnvironmentBlock(project.path)!;
    expect(fresh, contains('status: current'));
  });
}
