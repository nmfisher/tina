import 'dart:async';

import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

import 'package:tina_app/src/workflows/classify_handler.dart';

/// The `classify` program-node seam (docs/proposals/hierarchical_classifiers.md,
/// implementation slice 1). The runner is injected, so these tests exercise
/// the handler contract alone:
///   * stage resolution — `stage` attribute, falling back to the node id;
///   * transport — status, context updates, notes and failure reason pass
///     through untouched (the engine applies `contextUpdates` and routes on
///     the returned outcome);
///   * cancellation — once the engine's cancel signal fires, every settled
///     stage maps to `fail("cancelled")`, success or failure;
///   * exceptions — runner failures propagate for the engine's retry/record
///     policy, except under cancellation;
///   * audit — every returned outcome is written to the run store.
void main() {
  PipelineNode node(Map<String, Object> attrs, {String id = 'language'}) =>
      PipelineNode(id: id, attrs: attrs);

  MemoryRunStore store() => MemoryRunStore();

  ClassifyHandler handlerWith(ClassifyStageRunner runner) =>
      ClassifyHandler(runner);

  group('stage resolution', () {
    test('uses the stage attribute when present and non-blank', () async {
      String? seen;
      final handler = handlerWith(({required stage, cancelSignal}) async {
        seen = stage;
        return const ClassifyStageResult(status: StageStatus.success);
      });

      await handler.execute(
        node: node(const {'type': 'classify', 'stage': 'details'}),
        graph: _graph,
        context: Context(),
        runStore: store(),
      );

      expect(seen, 'details');
    });

    test('falls back to the node id when the attribute is missing', () async {
      String? seen;
      final handler = handlerWith(({required stage, cancelSignal}) async {
        seen = stage;
        return const ClassifyStageResult(status: StageStatus.success);
      });

      await handler.execute(
        node: node(const {'type': 'classify'}),
        graph: _graph,
        context: Context(),
        runStore: store(),
      );

      expect(seen, 'language');
    });

    test('treats a blank stage attribute as absent', () async {
      String? seen;
      final handler = handlerWith(({required stage, cancelSignal}) async {
        seen = stage;
        return const ClassifyStageResult(status: StageStatus.success);
      });

      await handler.execute(
        node: node(const {'type': 'classify', 'stage': '   '}),
        graph: _graph,
        context: Context(),
        runStore: store(),
      );

      expect(seen, 'language');
    });
  });

  group('outcome transport', () {
    test(
      'passes status, context updates, notes and failure reason through',
      () async {
        final handler = handlerWith(({required stage, cancelSignal}) async {
          return const ClassifyStageResult(
            status: StageStatus.partialSuccess,
            contextUpdates: {
              'label.dart': 'true',
              'coverage.complete': 'true',
              'outcome.classified': 'true',
            },
            notes: '2 classified, 1 incomplete',
            failureReason: 'dir "vendor" has incomplete coverage',
          );
        });

        final outcome = await handler.execute(
          node: node(const {'type': 'classify'}),
          graph: _graph,
          context: Context(),
          runStore: store(),
        );

        expect(outcome.status, StageStatus.partialSuccess);
        expect(outcome.contextUpdates, {
          'label.dart': 'true',
          'coverage.complete': 'true',
          'outcome.classified': 'true',
        });
        expect(outcome.notes, '2 classified, 1 incomplete');
        expect(outcome.failureReason, 'dir "vendor" has incomplete coverage');
      },
    );

    test('forwards a fail status with its reason', () async {
      final handler = handlerWith(({required stage, cancelSignal}) async {
        return const ClassifyStageResult(
          status: StageStatus.fail,
          failureReason: 'no classification records',
        );
      });

      final outcome = await handler.execute(
        node: node(const {'type': 'classify'}),
        graph: _graph,
        context: Context(),
        runStore: store(),
      );

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, 'no classification records');
    });

    test('forwards a retry status so the engine can re-run the node', () async {
      final handler = handlerWith(({required stage, cancelSignal}) async {
        return const ClassifyStageResult(status: StageStatus.retry);
      });

      final outcome = await handler.execute(
        node: node(const {'type': 'classify'}),
        graph: _graph,
        context: Context(),
        runStore: store(),
      );

      expect(outcome.status, StageStatus.retry);
    });
  });

  group('cancellation', () {
    test('maps a stage settled after cancel to fail("cancelled")', () async {
      final cancel = Completer<void>();
      final gate = Completer<void>();
      final handler = handlerWith(({required stage, cancelSignal}) async {
        await gate.future;
        return const ClassifyStageResult(
          status: StageStatus.success,
          notes: 'finished anyway',
        );
      });

      final outcomeFuture = handler.execute(
        node: node(const {'type': 'classify'}),
        graph: _graph,
        context: Context(),
        runStore: store(),
        cancelSignal: cancel.future,
      );
      cancel.complete();
      gate.complete();
      final outcome = await outcomeFuture;

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, 'cancelled');
      expect(outcome.contextUpdates, isEmpty);
    });

    test('swallows a runner exception under cancellation', () async {
      final cancel = Completer<void>()..complete();
      final gate = Completer<void>();
      final handler = handlerWith(({required stage, cancelSignal}) async {
        await gate.future;
        throw StateError('classification cancelled');
      });

      final outcomeFuture = handler.execute(
        node: node(const {'type': 'classify'}),
        graph: _graph,
        context: Context(),
        runStore: store(),
        cancelSignal: cancel.future,
      );
      gate.complete();
      final outcome = await outcomeFuture;

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, 'cancelled');
    });
  });

  group('exceptions', () {
    test(
      'propagates runner failures for the engine to record and retry',
      () async {
        final handler = handlerWith(({required stage, cancelSignal}) async {
          throw StateError('store unavailable');
        });

        expect(
          handler.execute(
            node: node(const {'type': 'classify'}),
            graph: _graph,
            context: Context(),
            runStore: store(),
          ),
          throwsA(isStateError),
        );
      },
    );
  });

  group('audit trail', () {
    test('writes every returned outcome to the run store', () async {
      final handler = handlerWith(({required stage, cancelSignal}) async {
        return const ClassifyStageResult(
          status: StageStatus.success,
          notes: 'ok',
        );
      });

      final runStore = store();
      await handler.execute(
        node: node(const {'type': 'classify'}),
        graph: _graph,
        context: Context(),
        runStore: runStore,
      );

      expect(runStore.nodes, hasLength(1));
      expect(runStore.nodes.single.nodeId, 'language');
      expect(runStore.nodes.single.outcome.status, StageStatus.success);
      expect(runStore.nodes.single.response, 'ok');
    });

    test('a failed stage records its reason as the node response', () async {
      final handler = handlerWith(({required stage, cancelSignal}) async {
        return const ClassifyStageResult(
          status: StageStatus.fail,
          failureReason: 'all task failures',
        );
      });

      final runStore = store();
      await handler.execute(
        node: node(const {'type': 'classify'}),
        graph: _graph,
        context: Context(),
        runStore: runStore,
      );

      expect(runStore.nodes.single.response, 'all task failures');
    });
  });

  test('registry resolves type=classify to the handler', () {
    final handler = handlerWith(({required stage, cancelSignal}) async {
      return const ClassifyStageResult(status: StageStatus.success);
    });
    final registry = NodeHandlerRegistry()..register('classify', handler);

    expect(registry.resolve(node(const {'type': 'classify'})), same(handler));
  });
}

final _graph = Graph(name: 'classify_handler_test');
