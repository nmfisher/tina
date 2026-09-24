import 'package:attractor/attractor.dart';
import 'package:test/test.dart';
import 'package:tina_app/src/workflows/classify_engine.dart';
import 'package:tina_app/src/workflows/classify_handler.dart';
import 'package:tina_app/src/workflows/classify_program.dart';

/// Engine-level routing for classifier programs: these tests drive the stock
/// PipelineEngine + ClassifyHandler with spy stage runners to prove that DOT
/// edges (and edits to them) control which stages run — the migration proof
/// for docs/proposals/hierarchical_classifiers.md.
void main() {
  late List<String> called;
  late Map<String, ClassifyStageResult> results;

  setUp(() {
    called = [];
    results = {};
  });

  ClassifyStageRunner spy({Set<String> throwOn = const {}}) =>
      ({required String stage, Future<void>? cancelSignal}) async {
        called.add(stage);
        if (throwOn.contains(stage)) throw StateError('boom');
        return results[stage] ??
            const ClassifyStageResult(status: StageStatus.success);
      };

  Future<(Outcome, MemoryRunStore)> run(
    ClassifyProgram program, {
    ClassifyStageRunner? runner,
  }) async {
    final store = MemoryRunStore();
    final outcome = await runClassifyProgram(
      program: program,
      runStage: runner ?? spy(),
      runStore: store,
      runId: 'routing-test',
    );
    return (outcome, store);
  }

  Graph graphVia(List<PipelineEdge> edges) => Graph(
        name: 'routing',
        attrs: const {},
        nodes: {
          'start': PipelineNode(id: 'start', attrs: {'shape': 'Mdiamond'}),
          'language':
              PipelineNode(id: 'language', attrs: {'type': 'classify'}),
          'details':
              PipelineNode(id: 'details', attrs: {'type': 'classify'}),
          'exit': PipelineNode(id: 'exit', attrs: {'shape': 'Msquare'}),
        },
        edges: edges,
      );

  ClassifyProgram custom(List<PipelineEdge> edges) => ClassifyProgram(
        name: 'routing',
        origin: 'test',
        graph: graphVia(edges),
        diagnostics: const [],
      );

  test('the built-in program walks language, details, exit', () async {
    final (outcome, store) = await run(builtinIndexProgram());

    expect(called, ['language', 'details']);
    expect(outcome.status, StageStatus.success);
    expect(store.finalStatus, StageStatus.success);
    expect(
      store.checkpoints.last.completed,
      ['start', 'language', 'details'],
    );
  });

  test('a failed language stage ends the run before details', () async {
    results['language'] = const ClassifyStageResult(
      status: StageStatus.fail,
      failureReason: 'service down',
    );

    final (outcome, store) = await run(builtinIndexProgram());

    expect(called, ['language'], reason: 'details must not run after a fail');
    expect(outcome.status, StageStatus.fail);
    expect(outcome.failureReason, 'service down');
    expect(store.finalStatus, StageStatus.fail);
    expect(store.checkpoints.last.completed, ['start', 'language']);
  });

  test('a language exception fails the run once (no silent retries)', () async {
    final (outcome, store) =
        await run(builtinIndexProgram(), runner: spy(throwOn: {'language'}));

    expect(called, ['language'], reason: 'graph default_max_retries is 0');
    expect(outcome.status, StageStatus.fail);
    expect(outcome.failureReason, contains('handler error in "language"'));
    expect(store.finalStatus, StageStatus.fail);
  });

  test('partial_success is ok: details still runs', () async {
    results['language'] = const ClassifyStageResult(
      status: StageStatus.partialSuccess,
      failureReason: '',
    );

    final (outcome, _) = await run(builtinIndexProgram());

    expect(called, ['language', 'details']);
    expect(outcome.status, StageStatus.success);
  });

  test('a failed details stage ends the run without reaching exit', () async {
    results['details'] = const ClassifyStageResult(
      status: StageStatus.fail,
      failureReason: 'configure Typesafe',
    );

    final (outcome, store) = await run(builtinIndexProgram());

    expect(called, ['language', 'details']);
    expect(outcome.status, StageStatus.fail);
    expect(outcome.failureReason, 'configure Typesafe');
    expect(store.checkpoints.last.completed, ['start', 'language', 'details']);
  });

  test('deleting the details edge reroutes without code changes', () async {
    final program = custom([
      PipelineEdge(from: 'start', to: 'language'),
      PipelineEdge(from: 'language', to: 'exit'),
    ]);

    final (outcome, store) = await run(program);

    expect(called, ['language'], reason: 'details is unreachable by edit');
    expect(outcome.status, StageStatus.success);
    expect(store.checkpoints.last.completed, ['start', 'language']);
  });

  group('published boolean context keys route stock conditions', () {
    List<PipelineEdge> conditionalEdges() => [
          PipelineEdge(from: 'start', to: 'language'),
          PipelineEdge(
            from: 'language',
            to: 'details',
            condition: 'outcome.classified=true',
          ),
          PipelineEdge(
            from: 'language',
            to: 'exit',
            condition: 'outcome.classified=false',
          ),
        ];

    test('classified=false takes the exit edge, skipping details', () async {
      results['language'] = const ClassifyStageResult(
        status: StageStatus.success,
        contextUpdates: {'outcome.classified': 'false'},
      );

      final (outcome, store) = await run(custom(conditionalEdges()));

      expect(called, ['language']);
      expect(outcome.status, StageStatus.success);
      expect(store.checkpoints.last.completed, ['start', 'language']);
    });

    test('classified=true takes the details edge', () async {
      results['language'] = const ClassifyStageResult(
        status: StageStatus.success,
        contextUpdates: {'outcome.classified': 'true'},
      );

      final (outcome, store) = await run(custom(conditionalEdges()));

      expect(called, ['language', 'details']);
      expect(outcome.status, StageStatus.success);
      expect(
        store.checkpoints.last.completed,
        ['start', 'language', 'details'],
      );
    });
  });
}
