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
}) async {
  final store = MemoryRunStore();
  final engine = PipelineEngine(
    graph: g,
    registry: _registry(backend, interviewer ?? _FakeInterviewer([])),
    runStore: store,
    runId: 'r1',
    workflowName: g.name,
    backoffFor: (_) => Duration.zero,
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
          build [shape=box, role="implementer"]
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
      // preamble (the prior-work section).
      final buildPreamble =
          backend.calls.firstWhere((c) => c.nodeId == 'build').preamble;
      expect(buildPreamble, contains('--- plan ---'));
      expect(buildPreamble, contains('response for plan'));
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
  });
}
