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
import 'package:tina/environment/environment_index.dart';
import 'package:tina/environment/environment_runner.dart';
import 'package:tina/environment/environment_store.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../summaries/fleet_test_harness.dart';

/// Scripts the environment agent's turns:
///
///   1. `write` ENVIRONMENT.md at the repo root (tool_use)
///   2. final report (end_turn)
///
/// With [writesRecord] false, turn 1 is prose only — an agent that answers
/// without ever invoking its write tool (the tin-h5nm false-success shape).
/// On a warm load the write carries an updated baseline so the record's
/// content actually changes.
class ScriptedEnvProvider extends LlmProvider {
  int callCount = 0;
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
    callCount++;
    const usage = TokenUsage(inputTokens: 100, outputTokens: 50);
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
        final warm = File('$projectPath/ENVIRONMENT.md').existsSync();
        yield MessageComplete(
          content: [
            ToolUseBlock(
              id: 'w1',
              name: 'write',
              input: {
                'filePath': '$projectPath/ENVIRONMENT.md',
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

void main() {
  late Directory tempRoot;
  late Directory project;

  setUp(() {
    final t = buildTempProject();
    tempRoot = t.tempRoot;
    project = t.project;
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
    final record = File('${project.path}/ENVIRONMENT.md');
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
    expect(File('${project.path}/ENVIRONMENT.md').existsSync(), isFalse);
    final store = EnvironmentTrackingStore(projectRoot: project.path);
    expect(store.load(), isNull);
    expect(store.staleReason(), isNotNull);
  });

  test('a warm re-verify that leaves the record unchanged is not a success',
      () async {
    File('${project.path}/ENVIRONMENT.md').writeAsStringSync('''
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
    File('${project.path}/ENVIRONMENT.md').writeAsStringSync('''
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
    final record = File('${project.path}/ENVIRONMENT.md');
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

  test('projectEnvironmentBlock renders the record + machine status', () {
    // No record yet: nothing to warm-load.
    expect(projectEnvironmentBlock(project.path), isNull);

    // A record with no tracking entry: present but STALE (never measured).
    File('${project.path}/ENVIRONMENT.md').writeAsStringSync('''
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
