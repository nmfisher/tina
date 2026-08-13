import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../lib/pipeline/file_run_store.dart';
import '../lib/pipeline/tina_codergen_backend.dart';
import 'helpers/fake_agent_sink.dart';

/// A scheduler stub that records the system prompt + model reference it was
/// asked to run with instead of actually spawning an agent.
class _RecordingScheduler extends SubAgentScheduler {
  String? seenModelReference;
  String? seenParentReference;
  String? seenSystemPrompt;
  int calls = 0;

  _RecordingScheduler()
      : super(
          registry: ProviderRegistry(env: const {}),
          pipeline: defaultPipeline,
          maxTokens: 1000,
          streamIdleTimeout: const Duration(seconds: 10),
          requestTimeout: const Duration(seconds: 10),
        );

  @override
  Future<RunAgentResult> runStandalone({
    required String systemPrompt,
    required String task,
    String parentReference = '',
    String? modelReference,
    List<Message>? seedHistory,
    Future<void>? cancelSignal,
    required AgentSink sink,
    ToolProfile toolProfile = ToolProfile.full,
    bool includeDelegate = true,
    PermissionPolicy? parentPolicy,
  }) async {
    calls++;
    seenModelReference = modelReference;
    seenParentReference = parentReference;
    seenSystemPrompt = systemPrompt;
    return const RunAgentResult('done');
  }
}

void main() {
  group('TinaCodergenBackend.parseVerdict', () {
    test('extracts a trailing VERDICT label, lowercased', () {
      expect(TinaCodergenBackend.parseVerdict('review text\n\nVERDICT: approve'),
          'approve');
      expect(TinaCodergenBackend.parseVerdict('notes\nverdict: Revise'),
          'revise');
    });

    test('ignores a VERDICT that is not on the last non-empty line', () {
      // A mid-text mention shouldn't route.
      expect(
          TinaCodergenBackend.parseVerdict('VERDICT: approve\nmore thoughts\n'),
          isNull);
    });

    test('returns null when there is no verdict line', () {
      expect(TinaCodergenBackend.parseVerdict('just a normal response'), isNull);
    });
  });

  group('TinaCodergenBackend node attributes', () {
    test('llm_model/llm_provider override the inherited conversation model', () async {
      final scheduler = _RecordingScheduler();
      final backend = TinaCodergenBackend(
        scheduler: scheduler,
        sink: FakeAgentSink(),
        defaultModelReference: 'anthropic/claude-sonnet-4-6',
      );
      final node = PipelineNode(id: 'main', attrs: {
        'llm_model': 'deepseek-chat',
        'llm_provider': 'deepseek',
      });
      final result = await backend.run(
        node: node,
        prompt: 'do it',
        preamble: '',
        context: Context(),
      );
      expect(result.outcome, isNull); // not an error result
      expect(scheduler.calls, 1);
      expect(scheduler.seenModelReference, 'deepseek/deepseek-chat');
      expect(scheduler.seenParentReference, 'anthropic/claude-sonnet-4-6');
    });

    test('a node without model attrs inherits the conversation model', () async {
      final scheduler = _RecordingScheduler();
      final backend = TinaCodergenBackend(
        scheduler: scheduler,
        sink: FakeAgentSink(),
        defaultModelReference: 'anthropic/claude-sonnet-4-6',
      );
      final node = PipelineNode(id: 'main', attrs: {});
      await backend.run(
        node: node,
        prompt: 'do it',
        preamble: '',
        context: Context(),
      );
      expect(scheduler.seenModelReference, isNull);
      expect(scheduler.seenParentReference, 'anthropic/claude-sonnet-4-6');
    });

    test('a node system_prompt is passed through as the agent identity', () async {
      final scheduler = _RecordingScheduler();
      final backend = TinaCodergenBackend(
        scheduler: scheduler,
        sink: FakeAgentSink(),
        defaultModelReference: 'anthropic/claude-sonnet-4-6',
      );
      final node = PipelineNode(id: 'main', attrs: {
        'system_prompt': 'You are the main agent.',
      });
      await backend.run(
        node: node,
        prompt: 'do it',
        preamble: '',
        context: Context(),
      );
      expect(scheduler.seenSystemPrompt, 'You are the main agent.');
    });

    test('a node without a system_prompt gets the default identity', () async {
      final scheduler = _RecordingScheduler();
      final backend = TinaCodergenBackend(
        scheduler: scheduler,
        sink: FakeAgentSink(),
        defaultModelReference: 'anthropic/claude-sonnet-4-6',
      );
      final node = PipelineNode(id: 'main', attrs: {});
      await backend.run(
        node: node,
        prompt: 'do it',
        preamble: '',
        context: Context(),
      );
      expect(scheduler.seenSystemPrompt, isNotEmpty);
    });

    test('onNodeStart fires before the agent runs, with id + full task',
        () async {
      final scheduler = _RecordingScheduler();
      final seen = <String>[];
      final backend = TinaCodergenBackend(
        scheduler: scheduler,
        sink: FakeAgentSink(),
        defaultModelReference: 'anthropic/claude-sonnet-4-6',
        onNodeStart: (id, task) => seen.add('$id|$task'),
      );
      final node = PipelineNode(id: 'intake', attrs: {});
      await backend.run(
        node: node,
        prompt: 'explore the repo',
        preamble: '--- plan ---\nthe plan',
        context: Context(),
      );
      // The full task as received: preamble + prompt.
      expect(seen.single, 'intake|--- plan ---\nthe plan\n\nexplore the repo');
      expect(scheduler.calls, 1);
    });

    test('onNodeStart defaults to unset (headless runs stay as-is)', () async {
      final scheduler = _RecordingScheduler();
      final backend = TinaCodergenBackend(
        scheduler: scheduler,
        sink: FakeAgentSink(),
        defaultModelReference: 'anthropic/claude-sonnet-4-6',
      );
      await backend.run(
        node: PipelineNode(id: 'main', attrs: {}),
        prompt: 'do it',
        preamble: '',
        context: Context(),
      );
      expect(scheduler.calls, 1);
    });
  });

  group('FileRunStore', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tina_run_'));

    tearDown(() => tmp.deleteSync(recursive: true));

    test('writes manifest, per-node files, and a checkpoint', () async {
      final runDir = Directory(p.join(tmp.path, 'run1'));
      final store = FileRunStore(runDir);

      await store.init(runId: 'run1', workflowName: 'wf', goal: 'g', input: 'in');
      await store.writeNode(
        nodeId: 'plan',
        outcome: const Outcome.success(),
        prompt: 'do it',
        response: 'a plan',
      );
      await store.writeCheckpoint(
          currentNode: 'plan', completedNodes: ['plan'], context: Context());
      await store.finalize(status: StageStatus.success);

      expect(File(p.join(runDir.path, 'manifest.json')).existsSync(), isTrue);
      expect(File(p.join(runDir.path, 'plan', 'prompt.md')).readAsStringSync(),
          'do it');
      expect(File(p.join(runDir.path, 'plan', 'response.md')).readAsStringSync(),
          'a plan');
      expect(File(p.join(runDir.path, 'plan', 'status.json')).existsSync(),
          isTrue);
      expect(File(p.join(runDir.path, 'checkpoint.json')).existsSync(), isTrue);
    });
  });
}
