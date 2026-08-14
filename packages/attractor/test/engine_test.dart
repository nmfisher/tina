import 'dart:async';

import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

/// A scripted codergen backend: each node id maps to a result. Unscripted
/// nodes echo their prompt.
class _FakeBackend implements CodergenBackend {
  final Map<String, CodergenResult> scripted;

  /// If set, consulted before [scripted]; lets a test return dynamic results
  /// per call (e.g. a reviewer that revises twice then approves).
  CodergenResult? Function(String id)? scriptedOverride;

  final List<({String nodeId, String prompt, String preamble})> calls = [];

  _FakeBackend(this.scripted);

  @override
  Future<CodergenResult> run({
    required PipelineNode node,
    required String prompt,
    required String preamble,
    required Context context,
    Future<void>? cancelSignal,
  }) async {
    calls.add((nodeId: node.id, prompt: prompt, preamble: preamble));
    if (scriptedOverride != null) {
      final r = scriptedOverride!(node.id);
      if (r != null) return r;
    }
    return scripted[node.id] ?? CodergenResult('response for ${node.id}');
  }
}

/// A scripted interviewer: returns one answer per gate, in order.
class _FakeInterviewer implements Interviewer {
  final List<Answer> answers;
  int _i = 0;
  _FakeInterviewer(this.answers);

  @override
  Future<Answer> ask(Question question) async =>
      _i < answers.length ? answers[_i++] : const Answer.cancelled();

  @override
  Future<void> inform(String message, {String? stage}) async {}
}

NodeHandlerRegistry _registry(CodergenBackend backend, Interviewer interviewer) {
  final r = NodeHandlerRegistry();
  r.register('start', StartHandler());
  r.register('exit', ExitHandler());
  r.register('conditional', ConditionalHandler());
  r.register('codergen', CodergenHandler(backend));
  r.register('wait.human', HumanGateHandler(interviewer));
  return r;
}

Future<(Outcome, MemoryRunStore)> _run(
  Graph g, {
  required _FakeBackend backend,
  _FakeInterviewer? interviewer,
  String? input,
  Map<String, String>? seedContext,
  PipelineEventListener? onEvent,
  Future<bool> Function(String reason)? onLoopBudgetExceeded,
}) async {
  final store = MemoryRunStore();
  final engine = PipelineEngine(
    graph: g,
    registry: _registry(backend, interviewer ?? _FakeInterviewer([])),
    runStore: store,
    runId: 'r1',
    workflowName: g.name,
    backoffFor: (_) => Duration.zero,
    onEvent: onEvent,
    onLoopBudgetExceeded: onLoopBudgetExceeded,
  );
  final outcome =
      await engine.run(input: input, seedContext: seedContext);
  return (outcome, store);
}

void main() {
  group('PipelineEngine', () {
    test('runs a linear pipeline and propagates context', () async {
      final g = parseDot('''
        digraph Linear {
          graph [goal="do the thing"]
          start [shape=Mdiamond]
          plan [shape=box, role="orchestrator", prompt="plan: \$goal"]
          build [shape=box, role="implementer", context="plan"]
          exit [shape=Msquare]
          start -> plan -> build -> exit
        }
      ''');
      final backend = _FakeBackend({});
      final (outcome, store) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.success);
      // plan ran before build.
      expect(store.nodes.map((n) => n.nodeId), ['plan', 'build']);
      // plan's own prompt had $goal expanded.
      expect(backend.calls.first.prompt, 'plan: do the thing');
      // plan's response was stored under context.plan and carried into build's
      // preamble — but only because build declared context="plan".
      final buildPreamble =
          backend.calls.firstWhere((c) => c.nodeId == 'build').preamble;
      expect(buildPreamble, contains('--- plan ---'));
      expect(buildPreamble, contains('response for plan'));
    });

    test('a node without a context attr gets an empty preamble (strict)',
        () async {
      final g = parseDot('''
        digraph Strict {
          start [shape=Mdiamond]
          plan [shape=box]
          build [shape=box]
          exit [shape=Msquare]
          start -> plan -> build -> exit
        }
      ''');
      final backend = _FakeBackend({});
      final (outcome, _) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.success);
      // plan ran and wrote context.plan, but build declared no context — it
      // sees nothing: nothing accumulates by default.
      expect(
          backend.calls.firstWhere((c) => c.nodeId == 'build').preamble, '');
    });

    test('context keys render in declared order; missing keys render nothing',
        () async {
      final g = parseDot('''
        digraph Ordered {
          start [shape=Mdiamond]
          a [shape=box]
          b [shape=box]
          c [shape=box, context="b,a,ghost"]
          exit [shape=Msquare]
          start -> a -> b -> c -> exit
        }
      ''');
      final backend = _FakeBackend({});
      final (outcome, _) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.success);
      final preamble =
          backend.calls.firstWhere((c) => c.nodeId == 'c').preamble;
      // Declared order (b before a — the reverse of insertion order), and the
      // unknown key renders nothing.
      expect(preamble.indexOf('--- b ---'), lessThan(preamble.indexOf('--- a ---')));
      expect(preamble, isNot(contains('ghost')));
      expect(preamble, contains('response for a'));
    });

    test('writes re-publishes the output: readers of the shared key always '
        'see the latest revision', () async {
      final g = parseDot('''
        digraph SharedKey {
          start [shape=Mdiamond]
          plan [shape=box]
          review [shape=box, context="plan", writes="plan"]
          execute [shape=box, context="plan"]
          done [shape=Msquare]
          start -> plan -> review
          review -> execute [label="approve"]
          review -> review [label="revise"]
          execute -> done
        }
      ''');
      final reviewTexts = <String>[];
      final scripted = _FakeBackend({})..scriptedOverride = (id) {
          if (id == 'review') {
            reviewTexts.add('revised plan v${reviewTexts.length + 1}');
            final v = reviewTexts.length;
            return CodergenResult('revised plan v$v',
                outcome: v < 3
                    ? const Outcome.success(preferredLabel: 'revise')
                    : const Outcome.success(preferredLabel: 'approve'));
          }
          return CodergenResult('output of $id');
        };

      final (outcome, _) = await _run(g, backend: scripted);

      expect(outcome.status, StageStatus.success);
      final calls = scripted.calls.where((c) => c.nodeId == 'review').toList();
      expect(calls.length, 3);
      // Each revisit reads the shared `plan` key — which now holds the
      // PREVIOUS visit's revision, not the original plan: the self-loop
      // refreshes without threading a revision chain through preambles.
      expect(calls[1].preamble, contains('--- plan ---'));
      expect(calls[1].preamble, contains('revised plan v1'));
      expect(calls[1].preamble, isNot(contains('output of plan')));
      expect(calls[2].preamble, contains('revised plan v2'));
      // The executor reads the final approved plan from the same key.
      final execPreamble =
          scripted.calls.firstWhere((c) => c.nodeId == 'execute').preamble;
      expect(execPreamble, contains('revised plan v3'));
    });

    test('expands any \$<key> token from the run context', () async {
      final g = parseDot('''
        digraph Expand {
          graph [goal="the goal"]
          start [shape=Mdiamond]
          plan [shape=box, role="orchestrator",
                prompt="plan: \$goal | \$input | \$history | \$missing"]
          exit [shape=Msquare]
          start -> plan -> exit
        }
      ''');
      final backend = _FakeBackend({});
      final (outcome, _) = await _run(g,
          backend: backend,
          input: 'user message',
          seedContext: {'history': 'user: hi\\nassistant: hello'});
      expect(outcome.status, StageStatus.success);
      // $goal aliases the graph goal; $input/$history come from the context;
      // unknown tokens stay verbatim.
      expect(backend.calls.first.prompt,
          'plan: the goal | user message | user: hi\\nassistant: hello | \$missing');
    });

    test('a trailing period after \$<key> is not part of the token', () async {
      final g = parseDot('''
        digraph Dot {
          start [shape=Mdiamond]
          plan [shape=box, role="orchestrator",
                prompt="implement \$input. then \$input."]
          exit [shape=Msquare]
          start -> plan -> exit
        }
      ''');
      final backend = _FakeBackend({});
      final (outcome, _) = await _run(g, backend: backend, input: 'the fix');
      expect(outcome.status, StageStatus.success);
      expect(backend.calls.first.prompt, 'implement the fix. then the fix.');
    });

    test('follows a verdict back-edge loop then approves', () async {
      // reviewer returns revise twice, then approve.
      final g = parseDot('''
        digraph Loop {
          start [shape=Mdiamond]
          plan [shape=box, role="orchestrator"]
          review [shape=box, role="verifier",
                  prompt="verdict please"]
          execute [shape=box, role="implementer", goal_gate=true]
          done [shape=Msquare]
          start -> plan -> review
          review -> execute [label="approve"]
          review -> plan [label="revise"]
          execute -> done
        }
      ''');
      // Script per-node behavior via a custom backend.
      var reviewCalls = 0;
      final scripted = _FakeBackend({})..scriptedOverride = (id) {
          if (id == 'review') {
            reviewCalls++;
            if (reviewCalls <= 2) {
              return CodergenResult('revise it',
                  outcome: const Outcome.success(preferredLabel: 'revise'));
            }
            return CodergenResult('looks good',
                outcome: const Outcome.success(preferredLabel: 'approve'));
          }
          return CodergenResult('output of $id');
        };

      final (outcome, store) = await _run(g, backend: scripted);

      expect(outcome.status, StageStatus.success);
      // review ran 3 times; plan ran 3 times; execute once.
      final reviewCount = store.nodes.where((n) => n.nodeId == 'review').length;
      final planCount = store.nodes.where((n) => n.nodeId == 'plan').length;
      final execCount = store.nodes.where((n) => n.nodeId == 'execute').length;
      expect(reviewCount, 3);
      expect(planCount, 3);
      expect(execCount, 1);
    });

    test('retries a RETRY outcome within max_retries then succeeds', () async {
      final g = parseDot('''
        digraph Retry {
          start [shape=Mdiamond]
          flaky [shape=box, max_retries=2]
          exit [shape=Msquare]
          start -> flaky -> exit
        }
      ''');
      var attempts = 0;
      final backend = _FakeBackend({})..scriptedOverride = (id) {
          attempts++;
          if (attempts < 3) {
            return CodergenResult('not yet', outcome: Outcome.retry('transient'));
          }
          return CodergenResult('done');
        };
      final (outcome, _) = await _run(g, backend: backend);
      expect(outcome.status, StageStatus.success);
      expect(attempts, 3); // 1 initial + 2 retries.
    });

    test('goal gate failure with no retry target fails the run', () async {
      final g = parseDot('''
        digraph Gate {
          start [shape=Mdiamond]
          critical [shape=box, goal_gate=true]
          exit [shape=Msquare]
          start -> critical -> exit
        }
      ''');
      final backend = _FakeBackend({
        'critical':
            CodergenResult('broke', outcome: Outcome.fail('nope')),
      });
      final (outcome, _) = await _run(g, backend: backend);
      expect(outcome.status, StageStatus.fail);
    });

    test('human gate routes on the interviewer answer', () async {
      final g = parseDot('''
        digraph Human {
          start [shape=Mdiamond]
          gate [shape=hexagon, label="Approve?"]
          ship [shape=box]
          fix [shape=box]
          exit [shape=Msquare]
          start -> gate
          gate -> ship [label="[A] Approve"]
          gate -> fix [label="[F] Fix"]
          ship -> exit
          fix -> exit
        }
      ''');
      // Approve -> Option key 'A' matches the first edge.
      final interviewer =
          _FakeInterviewer([Answer(value: 'A', selectedOption: Option(key: 'A', label: '[A] Approve'))]);
      final backend = _FakeBackend({});
      final (outcome, store) =
          await _run(g, backend: backend, interviewer: interviewer);
      expect(outcome.status, StageStatus.success);
      // 'ship' ran (approved), 'fix' did not.
      expect(store.nodes.any((n) => n.nodeId == 'ship'), isTrue);
      expect(store.nodes.any((n) => n.nodeId == 'fix'), isFalse);
    });

    test('edge selection: condition match wins over higher-weight unconditional',
        () async {
      final g = parseDot('''
        digraph Sel {
          start [shape=Mdiamond]
          gate [shape=diamond, label="g"]
          left [shape=box]
          right [shape=box]
          exit [shape=Msquare]
          start -> gate
          gate -> left [condition="outcome=success"]
          gate -> right [weight=10]
          left -> exit
          right -> exit
        }
      ''');
      final (outcome, store) = await _run(g, backend: _FakeBackend({}));
      expect(outcome.status, StageStatus.success);
      // 'left' is chosen because its condition matched.
      expect(store.nodes.any((n) => n.nodeId == 'left'), isTrue);
      expect(store.nodes.any((n) => n.nodeId == 'right'), isFalse);
    });

    test('cancellation terminates the run at the current node', () async {
      // The first working node cancels the run on its way out; the engine
      // must end there instead of walking the rest of the graph.
      final g = parseDot('''
        digraph Cancel {
          start [shape=Mdiamond]
          a [shape=box]
          b [shape=box]
          exit [shape=Msquare]
          start -> a -> b -> exit
        }
      ''');
      final cancel = Completer<void>();
      final backend = _FakeBackend({})..scriptedOverride = (id) {
          if (id == 'a') {
            if (!cancel.isCompleted) cancel.complete();
            return CodergenResult('done a');
          }
          return CodergenResult('output of $id');
        };
      final store = MemoryRunStore();
      final registry = _registry(backend, _FakeInterviewer([]));
      final events = <PipelineEvent>[];
      final engine = PipelineEngine(
        graph: g,
        registry: registry,
        runStore: store,
        runId: 'r1',
        workflowName: g.name,
        backoffFor: (_) => Duration.zero,
        cancelSignal: cancel.future,
        onEvent: events.add,
      );
      final outcome = await engine.run();

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, 'cancelled');
      // 'a' completed and was recorded; 'b' never ran and no node_failed
      // event was emitted for it.
      expect(store.nodes.map((n) => n.nodeId), ['a']);
      expect(events.where((e) => e.kind == 'node_failed'), isEmpty);
    });

    test('visit cap aborts an unbounded revise self-loop (no hook = abort)',
        () async {
      // The reviewer never approves; without the cap this loops forever.
      final g = parseDot('''
        digraph Spin {
          start [shape=Mdiamond]
          review [shape=box]
          exit [shape=Msquare]
          start -> review
          review -> review [label="revise"]
          review -> exit [label="approve"]
        }
      ''');
      final backend = _FakeBackend({})..scriptedOverride = (id) =>
          CodergenResult('again',
              outcome: const Outcome.success(preferredLabel: 'revise'));

      final (outcome, store) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, contains('exceeded 8 visits'));
      // The default cap: 8 visits, no more.
      final visits =
          store.nodes.where((n) => n.nodeId == 'review').length;
      expect(visits, 8);
    });

    test('visit-cap budget hook: continue resets the counter', () async {
      final g = parseDot('''
        digraph Reset {
          start [shape=Mdiamond]
          review [shape=box]
          exit [shape=Msquare]
          start -> review
          review -> review [label="revise"]
          review -> exit [label="approve"]
        }
      ''');
      var visits = 0;
      var hookCalls = 0;
      final backend = _FakeBackend({})..scriptedOverride = (id) {
          visits++;
          // Loop forever the first budget window; approve after the hook
          // once let it continue.
          final verdict = visits <= 8 ? 'revise' : 'approve';
          return CodergenResult(verdict,
              outcome: Outcome.success(preferredLabel: verdict));
        };

      final (outcome, _) = await _run(g, backend: backend,
          onLoopBudgetExceeded: (reason) async {
        hookCalls++;
        return true; // continue
      });

      expect(outcome.status, StageStatus.success);
      expect(hookCalls, 1);
      // 8 visits in the first window, then the 9th approves.
      expect(visits, 9);
    });

    test('a small max_node_visits graph attr tightens the cap', () async {
      final g = parseDot('''
        digraph Tight {
          graph [max_node_visits=2]
          start [shape=Mdiamond]
          review [shape=box]
          exit [shape=Msquare]
          start -> review
          review -> review [label="revise"]
          review -> exit [label="approve"]
        }
      ''');
      final backend = _FakeBackend({})..scriptedOverride = (id) =>
          CodergenResult('again',
              outcome: const Outcome.success(preferredLabel: 'revise'));

      final (outcome, store) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, contains('exceeded 2 visits'));
      expect(store.nodes.where((n) => n.nodeId == 'review').length, 2);
    });

    test('goal-gate retry jumps are bounded; budget exhausted fails clearly',
        () async {
      // critical is a goal gate that fails; retry_target loops back to it,
      // and it keeps failing — previously this jumped forever (stale
      // nodeOutcomes entry at the terminal check).
      final g = parseDot('''
        digraph Gate {
          graph [retry_target="critical"]
          start [shape=Mdiamond]
          critical [shape=box, goal_gate=true]
          exit [shape=Msquare]
          start -> critical -> exit
        }
      ''');
      final backend = _FakeBackend({
        'critical': CodergenResult('broke', outcome: Outcome.fail('nope')),
      });

      final (outcome, store) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason,
          contains('goal gate "critical" retry budget exhausted'));
      // default budget 2: initial visit + 2 retry jumps.
      expect(store.nodes.where((n) => n.nodeId == 'critical').length, 3);
    });

    test('total-step cap (max_steps) guards the whole run', () async {
      final g = parseDot('''
        digraph Steps {
          graph [max_steps=4]
          start [shape=Mdiamond]
          a [shape=box]
          b [shape=box]
          c [shape=box]
          d [shape=box]
          e [shape=box]
          exit [shape=Msquare]
          start -> a -> b -> c -> d -> e -> exit
        }
      ''');
      final (outcome, store) = await _run(g, backend: _FakeBackend({}));

      expect(outcome.status, StageStatus.fail);
      expect(outcome.failureReason, contains('exceeded 4 total steps'));
      // Every traversal iteration counts, including the start node: start,
      // a, b, c consume the 4 steps; 'd' never runs.
      expect(store.nodes.map((n) => n.nodeId), ['a', 'b', 'c']);
    });

    test('a transient backend error retries and does not clobber writes keys',
        () async {
      // flaky publishes to the shared `plan` key (writes) and fails
      // transiently once; the retry must not record '' under `plan`, and the
      // executor must see the eventual real output.
      final g = parseDot('''
        digraph Transient {
          start [shape=Mdiamond]
          flaky [shape=box, max_retries=1, writes="plan"]
          exec [shape=box, context="plan"]
          exit [shape=Msquare]
          start -> flaky -> exec -> exit
        }
      ''');
      var flakyAttempts = 0;
      final backend = _FakeBackend({})..scriptedOverride = (id) {
          if (id != 'flaky') return CodergenResult('output of $id');
          flakyAttempts++;
          if (flakyAttempts == 1) {
            return CodergenResult.error('provider hiccup', transient: true);
          }
          return CodergenResult('the real output');
        };

      final (outcome, _) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.success);
      expect(flakyAttempts, 2);
      final execPreamble =
          backend.calls.firstWhere((c) => c.nodeId == 'exec').preamble;
      expect(execPreamble, contains('the real output'));
      expect(execPreamble, isNot(contains('--- plan ---\n\n')));
    });

    test('a permanent backend error fails the node without retry', () async {
      // goal_gate keeps the failed node from routing on to exit, so the run
      // itself fails (edge-selection honesty for fail outcomes is its own
      // finding; the goal gate pins this test to the retry behavior).
      final g = parseDot('''
        digraph Perm {
          start [shape=Mdiamond]
          flaky [shape=box, max_retries=2, goal_gate=true]
          exit [shape=Msquare]
          start -> flaky -> exit
        }
      ''');
      var attempts = 0;
      final backend = _FakeBackend({})..scriptedOverride = (id) {
          attempts++;
          return CodergenResult.error('max steps reached');
        };

      final (outcome, _) = await _run(g, backend: backend);

      expect(outcome.status, StageStatus.fail);
      expect(attempts, 1); // permanent — no retry attempts spent
    });

    test('threads onEvent into handlers so a handler can emit progress',
        () async {
      // A handler that receives the engine's listener and emits its own
      // progress event through it — the seam parallel branches use.
      final g = parseDot('''
        digraph T {
          start [shape=Mdiamond]
          step [shape=box, type="spy"]
          exit [shape=Msquare]
          start -> step -> exit
        }
      ''');
      final backend = _FakeBackend({});
      final store = MemoryRunStore();
      final registry = _registry(backend, _FakeInterviewer([]));
      final spy = _SpyEmitHandler();
      registry.register('spy', spy);

      final events = <PipelineEvent>[];
      final engine = PipelineEngine(
        graph: g,
        registry: registry,
        runStore: store,
        runId: 'r1',
        workflowName: g.name,
        backoffFor: (_) => Duration.zero,
        onEvent: events.add,
      );
      final outcome = await engine.run();

      expect(outcome.status, StageStatus.success);
      // The handler saw the engine's listener…
      expect(spy.seenListener, isNotNull);
      // …and an event emitted from inside the handler surfaced at the engine.
      expect(events.any((e) => e.kind == 'node_started' && e.nodeId == 'step'),
          isTrue);
    });
  });
}

/// A spy handler: records the [PipelineEventListener] it received and emits a
/// progress event through it.
class _SpyEmitHandler implements NodeHandler {
  PipelineEventListener? seenListener;

  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    seenListener = onEvent;
    onEvent?.call(PipelineEvent('node_started', nodeId: node.id));
    return const Outcome.success();
  }
}
