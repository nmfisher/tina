import 'dart:async';

import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

// A scripted codergen backend: each node id maps to a result; unscripted nodes
// echo their id. Records each call's (nodeId, prompt, preamble) for assertions.
class _FakeBackend implements CodergenBackend {
  final Map<String, CodergenResult> scripted;
  _FakeBackend(this.scripted);

  final List<({String nodeId, String prompt, String preamble})> calls = [];

  @override
  Future<CodergenResult> run({
    required PipelineNode node,
    required String prompt,
    required String preamble,
    required Context context,
    Future<void>? cancelSignal,
  }) async {
    calls.add((nodeId: node.id, prompt: prompt, preamble: preamble));
    return scripted[node.id] ?? CodergenResult('response for ${node.id}');
  }
}

/// A branch handler that records which node ids it ran, in call order.
class _EchoHandler implements NodeHandler {
  final List<String> calls = [];
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    calls.add(node.id);
    return Outcome.success(contextUpdates: {node.id: 'out:${node.id}'});
  }
}

/// A branch handler that proves context isolation: it records the value of
/// context key `k` *before* writing it. If every branch saw an empty `k`, no
/// sibling's write leaked into another's context.
class _IsoHandler implements NodeHandler {
  final List<String> preValues = [];
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    preValues.add(context.getString('k'));
    context.set('k', node.id);
    return Outcome.success(contextUpdates: {node.id: 'out:${node.id}'});
  }
}

/// A branch handler that appends start/end markers to a shared log after a
/// short delay, so a test can assert branches actually overlapped (ran
/// concurrently), not strictly sequentially.
class _ConcurrencyHandler implements NodeHandler {
  final List<String> log;
  _ConcurrencyHandler(this.log);
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    log.add('start:${node.id}');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    log.add('end:${node.id}');
    return Outcome.success(contextUpdates: {node.id: 'out:${node.id}'});
  }
}

NodeHandlerRegistry _registryWithParallel(NodeHandlerRegistry registry) {
  registry.register('parallel', ParallelHandler(registry));
  registry.register('parallel.fan_in', ParallelFanInHandler());
  return registry;
}

Future<(Outcome, MemoryRunStore)> _run(Graph g,
    {required _FakeBackend backend, PipelineEventListener? onEvent}) async {
  final store = MemoryRunStore();
  final registry = NodeHandlerRegistry()
    ..register('start', StartHandler())
    ..register('exit', ExitHandler())
    ..register('conditional', ConditionalHandler())
    ..register('codergen', CodergenHandler(backend));
  _registryWithParallel(registry);
  final engine = PipelineEngine(
    graph: g,
    registry: registry,
    runStore: store,
    runId: 'r1',
    workflowName: g.name,
    backoffFor: (_) => Duration.zero,
    onEvent: onEvent,
  );
  final outcome = await engine.run();
  return (outcome, store);
}

void main() {
  group('ParallelHandler', () {
    test('runs every branch, stages outputs, and routes to the fan-in',
        () async {
      final g = parseDot('''
        digraph T {
          fanout [shape=component]
          exec_a [shape=box]
          exec_b [shape=box]
          fanin [shape=tripleoctagon]
          fanout -> exec_a
          fanout -> exec_b
          fanout -> fanin
        }
      ''');
      final registry = NodeHandlerRegistry();
      final echo = _EchoHandler();
      registry.register('codergen', echo);
      _registryWithParallel(registry);

      final outcome = await (registry.resolve(g.node('fanout')!) as ParallelHandler)
          .execute(
        node: g.node('fanout')!,
        graph: g,
        context: Context(),
        runStore: MemoryRunStore(),
        cancelSignal: null,
      );

      expect(outcome.status, StageStatus.success);
      // The engine routes onward via suggestedNextIds, which must be the
      // fan-in node (the only tripleoctagon successor).
      expect(outcome.suggestedNextIds, ['fanin']);
      // Both branches actually ran.
      expect(echo.calls.toSet(), {'exec_a', 'exec_b'});
      // Each branch's output is staged under an internal, fan-out-namespaced
      // key so the preamble skips it; the fan-in handler reads them back.
      expect(outcome.contextUpdates['internal.parallel.fanout.branch.exec_a'],
          'out:exec_a');
      expect(outcome.contextUpdates['internal.parallel.fanout.branch.exec_b'],
          'out:exec_b');
      expect(outcome.contextUpdates['internal.parallel.fanout.branches'],
          anyOf(['exec_a,exec_b', 'exec_b,exec_a']));
    });

    test('clones the context per branch — a branch write does not leak',
        () async {
      final g = parseDot('''
        digraph T {
          fanout [shape=component]
          a [shape=box]
          b [shape=box]
          c [shape=box]
          fanin [shape=tripleoctagon]
          fanout -> a
          fanout -> b
          fanout -> c
          fanout -> fanin
        }
      ''');
      final registry = NodeHandlerRegistry();
      final iso = _IsoHandler();
      registry.register('codergen', iso);
      _registryWithParallel(registry);

      await (registry.resolve(g.node('fanout')!) as ParallelHandler).execute(
        node: g.node('fanout')!,
        graph: g,
        context: Context(),
        runStore: MemoryRunStore(),
        cancelSignal: null,
      );

      // Every branch saw an EMPTY `k` before writing: with cloned contexts no
      // sibling's write was visible. (A shared context would leak node ids.)
      expect(iso.preValues.length, 3);
      expect(iso.preValues.every((v) => v.isEmpty), isTrue);
    });

    test('branches run concurrently, not strictly sequentially', () async {
      final g = parseDot('''
        digraph T {
          fanout [shape=component]
          a [shape=box]
          b [shape=box]
          fanin [shape=tripleoctagon]
          fanout -> a
          fanout -> b
          fanout -> fanin
        }
      ''');
      final log = <String>[];
      final registry = NodeHandlerRegistry();
      registry.register('codergen', _ConcurrencyHandler(log));
      _registryWithParallel(registry);

      await (registry.resolve(g.node('fanout')!) as ParallelHandler).execute(
        node: g.node('fanout')!,
        graph: g,
        context: Context(),
        runStore: MemoryRunStore(),
        cancelSignal: null,
      );

      // `b` must have STARTED before `a` FINISHED — i.e. the branches
      // overlapped on the event loop, rather than one running fully first.
      expect(log.indexOf('start:b'), lessThan(log.indexOf('end:a')));
    });

    test('fails cleanly when there is no fan-in successor', () async {
      final g = parseDot('''
        digraph T {
          fanout [shape=component]
          a [shape=box]
          fanout -> a
        }
      ''');
      final registry = NodeHandlerRegistry();
      registry.register('codergen', _EchoHandler());
      _registryWithParallel(registry);

      final outcome = await (registry.resolve(g.node('fanout')!) as ParallelHandler)
          .execute(
        node: g.node('fanout')!,
        graph: g,
        context: Context(),
        runStore: MemoryRunStore(),
        cancelSignal: null,
      );

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, contains('fan-in'));
    });

    test('fails cleanly when there are no branches', () async {
      final g = parseDot('''
        digraph T {
          fanout [shape=component]
          fanin [shape=tripleoctagon]
          fanout -> fanin
        }
      ''');
      final registry = NodeHandlerRegistry();
      _registryWithParallel(registry);

      final outcome = await (registry.resolve(g.node('fanout')!) as ParallelHandler)
          .execute(
        node: g.node('fanout')!,
        graph: g,
        context: Context(),
        runStore: MemoryRunStore(),
        cancelSignal: null,
      );

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, contains('no branches'));
    });
  });

  group('ParallelFanInHandler', () {
    test('merges its fan-out predecessor’s staged branches into one result',
        () async {
      final g = parseDot('''
        digraph T {
          fanout [shape=component]
          a [shape=box]
          b [shape=box]
          fanin [shape=tripleoctagon]
          fanout -> a
          fanout -> b
          fanout -> fanin
        }
      ''');
      final ctx = Context()
        ..set('internal.parallel.fanout.branches', 'a,b')
        ..set('internal.parallel.fanout.branch.a', 'result A')
        ..set('internal.parallel.fanout.branch.b', 'result B');

      final outcome = await ParallelFanInHandler().execute(
        node: g.node('fanin')!,
        graph: g,
        context: ctx,
        runStore: MemoryRunStore(),
        cancelSignal: null,
      );

      expect(outcome.status, StageStatus.success);
      final merged = outcome.contextUpdates['fanin']!;
      expect(merged, contains('--- a ---'));
      expect(merged, contains('result A'));
      expect(merged, contains('--- b ---'));
      expect(merged, contains('result B'));
    });

    test('is a no-op success when no fan-out staged any branches', () async {
      final g = parseDot('''
        digraph T {
          fanin [shape=tripleoctagon]
          done [shape=Msquare]
          fanin -> done
        }
      ''');
      final outcome = await ParallelFanInHandler().execute(
        node: g.node('fanin')!,
        graph: g,
        context: Context(),
        runStore: MemoryRunStore(),
        cancelSignal: null,
      );
      expect(outcome.status, StageStatus.success);
      expect(outcome.contextUpdates['fanin'], contains('no branches'));
    });
  });

  group('engine integration (fan-out -> branches -> fan-in -> sink)', () {
    test('runs branches, merges at fan-in, and the sink sees the merged result',
        () async {
      final g = parseDot('''
        digraph T {
          start [shape=Mdiamond]
          fanout [shape=component]
          a [shape=box]
          b [shape=box]
          fanin [shape=tripleoctagon]
          sink [shape=box, context="fanin"]
          exit [shape=Msquare]
          start -> fanout
          fanout -> a
          fanout -> b
          fanout -> fanin
          fanin -> sink
          sink -> exit
        }
      ''');
      final backend = _FakeBackend({
        'a': CodergenResult('A did it'),
        'b': CodergenResult('B did it'),
      });

      final (outcome, store) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.success);
      // Both executors ran (recorded in the audit store).
      expect(store.nodes.any((n) => n.nodeId == 'a'), isTrue);
      expect(store.nodes.any((n) => n.nodeId == 'b'), isTrue);
      // The fan-in node ran and recorded its merged response.
      final fanIn = store.nodes.firstWhere((n) => n.nodeId == 'fanin');
      expect(fanIn.response, contains('A did it'));
      expect(fanIn.response, contains('B did it'));
      // The downstream sink's preamble carries the merged fan-in result — the
      // sink declared context="fanin"; the raw internal staging keys never
      // leak into a preamble.
      final sinkCall = backend.calls.firstWhere((c) => c.nodeId == 'sink');
      expect(sinkCall.preamble, contains('--- fanin ---'));
      expect(sinkCall.preamble, contains('A did it'));
      expect(sinkCall.preamble, contains('B did it'));
      expect(sinkCall.preamble, isNot(contains('internal.parallel')));
    });

    test('branches see only their declared context, never a sibling\'s output',
        () async {
      final g = parseDot('''
        digraph T {
          start [shape=Mdiamond]
          plan [shape=box]
          fanout [shape=component]
          a [shape=box, context="plan"]
          b [shape=box, context="plan"]
          fanin [shape=tripleoctagon]
          exit [shape=Msquare]
          start -> plan -> fanout
          fanout -> a
          fanout -> b
          fanout -> fanin
          fanin -> exit
        }
      ''');
      final backend = _FakeBackend({});
      final (outcome, _) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.success);
      // Each branch declares context="plan" — it sees the plan and nothing
      // else: not the sibling's output, not the fan-out staging.
      final aCall = backend.calls.firstWhere((c) => c.nodeId == 'a');
      final bCall = backend.calls.firstWhere((c) => c.nodeId == 'b');
      expect(aCall.preamble, contains('--- plan ---'));
      expect(aCall.preamble, contains('response for plan'));
      expect(aCall.preamble, isNot(contains('--- b ---')));
      expect(bCall.preamble, isNot(contains('--- a ---')));
      expect(aCall.preamble, isNot(contains('internal.parallel')));
    });

    test('a failed branch is surfaced in the merge; the pipeline continues',
        () async {
      final g = parseDot('''
        digraph T {
          start [shape=Mdiamond]
          fanout [shape=component]
          a [shape=box]
          b [shape=box]
          fanin [shape=tripleoctagon]
          sink [shape=box]
          exit [shape=Msquare]
          start -> fanout
          fanout -> a
          fanout -> b
          fanout -> fanin
          fanin -> sink
          sink -> exit
        }
      ''');
      // Branch `a` succeeds; branch `b` errors. The fan-out surfaces b's
      // failure as text inside the merge and still reaches success, so the
      // downstream sink (the reviewer) runs and sees what failed.
      final backend = _FakeBackend({
        'a': CodergenResult('A did it'),
        'b': CodergenResult.error('executor "b" crashed'),
      });
      final (outcome, store) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.success);
      // The failed branch's failure is surfaced inside the fan-in merge.
      final fanIn = store.nodes.firstWhere((n) => n.nodeId == 'fanin');
      expect(fanIn.response, contains('b'));
      expect(fanIn.response.toLowerCase(), contains('fail'));
      // The pipeline continued past the failed branch to the sink.
      expect(store.nodes.any((n) => n.nodeId == 'sink'), isTrue);
    });

    test('a cancelled branch is labeled cancelled, not failed, in the merge',
        () async {
      final g = parseDot('''
        digraph T {
          start [shape=Mdiamond]
          fanout [shape=component]
          a [shape=box]
          b [shape=box]
          fanin [shape=tripleoctagon]
          sink [shape=box]
          exit [shape=Msquare]
          start -> fanout
          fanout -> a
          fanout -> b
          fanout -> fanin
          fanin -> sink
          sink -> exit
        }
      ''');
      // Branch `a` succeeds; branch `b` was aborted by a stop — the same
      // `Outcome.fail('cancelled')` a backend returns when its cancel signal
      // fires. The merge must not call that a failure.
      final backend = _FakeBackend({
        'a': CodergenResult('A did it'),
        'b': CodergenResult('', outcome: Outcome.fail('cancelled')),
      });
      final (outcome, store) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.success);
      final fanIn = store.nodes.firstWhere((n) => n.nodeId == 'fanin');
      expect(fanIn.response, contains('(branch "b" cancelled)'));
      expect(fanIn.response, isNot(contains('failed')));
      // The fan-out's own tally counts the cancellation separately too.
      final fanout = store.nodes.firstWhere((n) => n.nodeId == 'fanout');
      expect(fanout.outcome.notes, contains('1 cancelled'));
      expect(fanout.outcome.notes, isNot(contains('failed')));
    });

    test('branch lifecycle events reach the engine listener', () async {
      final g = parseDot('''
        digraph T {
          start [shape=Mdiamond]
          fanout [shape=component]
          a [shape=box]
          b [shape=box]
          fanin [shape=tripleoctagon]
          exit [shape=Msquare]
          start -> fanout
          fanout -> a
          fanout -> b
          fanout -> fanin
          fanin -> exit
        }
      ''');
      final backend = _FakeBackend({
        'a': CodergenResult('A did it'),
        'b': CodergenResult.error('executor "b" crashed'),
      });
      final events = <PipelineEvent>[];
      final (outcome, _) = await _run(g,
          backend: backend, onEvent: events.add);

      expect(outcome.status, StageStatus.success);
      // Branch a: started → completed.
      final aStarted = events.where((e) =>
          e.kind == 'node_started' && e.nodeId == 'a');
      final aDone = events
          .where((e) => e.kind == 'node_completed' && e.nodeId == 'a');
      expect(aStarted, hasLength(1));
      expect(aDone, hasLength(1));
      // Branch b: started → failed with the failure reason.
      final bFailed = events
          .where((e) => e.kind == 'node_failed' && e.nodeId == 'b');
      expect(bFailed, hasLength(1));
      expect(bFailed.single.message, contains('crashed'));
      // The fan-out's own events still fire around the branches.
      expect(events.where((e) => e.nodeId == 'fanout'), isNotEmpty);
    });

    test('a branch handler that throws emits node_failed, not a crash', () async {
      final g = parseDot('''
        digraph T {
          fanout [shape=component]
          ok [shape=box]
          boom [shape=box, type="boom"]
          fanin [shape=tripleoctagon]
          fanout -> ok
          fanout -> boom
          fanout -> fanin
        }
      ''');
      final registry = NodeHandlerRegistry();
      registry.register('codergen', _EchoHandler());
      registry.register('boom', _ThrowingHandler());
      _registryWithParallel(registry);

      final events = <PipelineEvent>[];
      final outcome = await (registry.resolve(g.node('fanout')!)
              as ParallelHandler)
          .execute(
        node: g.node('fanout')!,
        graph: g,
        context: Context(),
        runStore: MemoryRunStore(),
        cancelSignal: null,
        onEvent: events.add,
      );

      // The fan-out itself still succeeds (the thrown branch is surfaced as a
      // failed branch), and the throwing branch reported node_failed.
      expect(outcome.status, StageStatus.success);
      final boomEvents = events.where((e) => e.nodeId == 'boom').toList();
      expect(boomEvents.map((e) => e.kind), ['node_started', 'node_failed']);
      expect(boomEvents.last.message, contains('branch error'));
    });
  });
}

/// A branch handler that throws — proves the fan-out's catch path reports the
/// branch as failed instead of crashing the run.
class _ThrowingHandler implements NodeHandler {
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async =>
      throw StateError('kaboom');
}
