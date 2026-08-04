// Shared scaffolding for the summary-fleet tests: a temp committed project,
// a scripted [LlmProvider] that drives the orchestrator→delegate→summarizer→
// write_summary turn sequence, and the registry/config wiring to serve both
// tiers from one scripted provider. Extracted so both [SummaryRunner] and
// [SummaryIndex] tests can drive the real fleet without duplicating ~80 lines.
//
// Both the orchestrator (heavy tier) and summarizer (light tier) resolve to
// `anthropic` in the default config's tier map, so one scripted `anthropic`
// provider serves both turns.

import 'dart:io';

import 'package:tina/config.dart';
import 'package:tina_engine/tina_engine.dart';

/// A committed temp project with one directory to summarize (`lib`).
/// Returns the project dir + its sidecar root (`<project>/.tina`).
({Directory project, Directory sidecarRoot, Directory tempRoot})
    buildTempProject() {
  final tempRoot = Directory.systemTemp.createTempSync('tina-summary-');
  final project = Directory('${tempRoot.path}/project')..createSync();
  final sidecarRoot = Directory('${project.path}/.tina');
  Directory('${project.path}/lib')..createSync();
  File('${project.path}/lib/a.dart').writeAsStringSync('int x = 1;\n');
  git(project, ['init']);
  git(project, ['add', '-A']);
  git(project, ['commit', '-m', 'init']);
  return (project: project, sidecarRoot: sidecarRoot, tempRoot: tempRoot);
}

/// The default config's tier map is anthropic/claude-sonnet-4-6 (heavy) +
/// anthropic/claude-haiku-4-5 (light), so both tiers resolve to `anthropic`.
/// We register one scripted `anthropic` provider to serve both turns. The API
/// key resolves via the registry's authFor against TEST_KEY.
Config testFleetConfig(ProviderRegistry registry) => Config.parse(
      const ['--backend', 'ansi'],
      env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'},
      registry: registry,
    );

ProviderRegistry anthropicRegistry(ScriptedFleetProvider provider) {
  final r = ProviderRegistry(env: const {'TEST_KEY': 'k', 'ANTHROPIC_API_KEY': 'k'});
  r.register(ProviderDescriptor(
    id: 'anthropic',
    name: 'Anthropic',
    authSources: const [
      AuthSource('ANTHROPIC_API_KEY', AuthScheme.apiKeyHeader),
    ],
    defaultBaseUrl: 'https://api.anthropic.com',
    builder: (_) => provider,
    models: const {
      'claude-sonnet-4-6':
          ModelInfo(id: 'claude-sonnet-4-6', name: 'm', contextWindow: 1, maxOutput: 1),
      'claude-haiku-4-5':
          ModelInfo(id: 'claude-haiku-4-5', name: 'm', contextWindow: 1, maxOutput: 1),
    },
  ));
  return r;
}

/// A provider that scripts the fleet turn-by-turn. Both the orchestrator and
/// the summarizer resolve to this one instance, so the call sequence is shared
/// and we key the script off the monotonic [callCount]:
///
///   1. orchestrator  → `delegate` to summarizer for lib (tool_use)
///   2. summarizer    → `write_summary` lib (tool_use)
///   3. summarizer    → final answer (end_turn)
///   4. orchestrator  → final answer (end_turn)
///
/// Each [send] yields exactly ONE [MessageComplete]: the stream consumer keeps
/// the last complete, so a turn that emits two would lose its tool call.
class ScriptedFleetProvider extends LlmProvider {
  int callCount = 0;

  ScriptedFleetProvider() : super('fleet');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    callCount++;
    switch (callCount) {
      case 1:
        // Orchestrator: delegate to summarizer for lib.
        yield MessageComplete(
          content: [
            ToolUseBlock(
              id: 'd1',
              name: 'delegate',
              input: {
                'delegations': [
                  {'agent': 'summarizer', 'task': 'read and summarize lib'},
                ],
              },
            ),
          ],
          stopReason: 'tool_use',
        );
      case 2:
        // Summarizer: write_summary, then finish on the next turn.
        yield MessageComplete(
          content: [
            ToolUseBlock(
              id: 'w1',
              name: 'write_summary',
              input: {
                'dir': 'lib',
                'content': '# lib\n\nlib does X',
              },
            ),
          ],
          stopReason: 'tool_use',
        );
      case 3:
        // Summarizer: final answer.
        yield MessageComplete(
          content: const [TextBlock('done')],
          stopReason: 'end_turn',
        );
      default:
        // Orchestrator: final answer after the delegation returns.
        yield MessageComplete(
          content: const [TextBlock('summarized 1 directory')],
          stopReason: 'end_turn',
        );
    }
  }
}

/// Run `git` in [dir] with a fixed test identity. Throws on failure.
String git(Directory dir, List<String> args) {
  final env = Map<String, String>.from(Platform.environment)
    ..['GIT_AUTHOR_NAME'] = 'Test'
    ..['GIT_AUTHOR_EMAIL'] = 'test@example.com'
    ..['GIT_COMMITTER_NAME'] = 'Test'
    ..['GIT_COMMITTER_EMAIL'] = 'test@example.com';
  final result = Process.runSync(
    'git',
    ['-C', dir.path, ...args],
    environment: env,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(" ")} failed in ${dir.path}: '
        '${result.stderr}');
  }
  return (result.stdout as String).trim();
}
