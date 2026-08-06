import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../lib/pipeline/file_run_store.dart';
import '../lib/pipeline/tina_codergen_backend.dart';
import 'helpers/fake_agent_sink.dart';

/// A scheduler stub that records the model reference it was asked to run with
/// instead of actually spawning an agent.
class _RecordingScheduler extends SubAgentScheduler {
  String? seenModelReference;
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
    required AgentRole role,
    required String task,
    String parentReference = '',
    String? modelReference,
    List<Message>? seedHistory,
    Future<void>? cancelSignal,
    required AgentSink sink,
  }) async {
    calls++;
    seenModelReference = modelReference;
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

  group('TinaCodergenBackend model attribute', () {
    test('a node model attr overrides the role tier', () async {
      final scheduler = _RecordingScheduler();
      final backend = TinaCodergenBackend(
        scheduler: scheduler,
        pipeline: defaultPipeline,
        sink: FakeAgentSink(),
      );
      final node = PipelineNode(id: 'review', attrs: {
        'role': 'verifier',
        'model': 'deepseek/deepseek-chat',
      });
      final result = await backend.run(
        node: node,
        role: 'verifier',
        prompt: 'review it',
        preamble: '',
        context: Context(),
      );
      expect(result.outcome, isNull); // not an error result
      expect(scheduler.calls, 1);
      expect(scheduler.seenModelReference, 'deepseek/deepseek-chat');
    });

    test('a node without a model attr passes null (tier wins)', () async {
      final scheduler = _RecordingScheduler();
      final backend = TinaCodergenBackend(
        scheduler: scheduler,
        pipeline: defaultPipeline,
        sink: FakeAgentSink(),
      );
      final node = PipelineNode(id: 'plan', attrs: {'role': 'orchestrator'});
      await backend.run(
        node: node,
        role: 'orchestrator',
        prompt: 'plan it',
        preamble: '',
        context: Context(),
      );
      expect(scheduler.seenModelReference, isNull);
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
