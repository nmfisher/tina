import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../lib/pipeline/default_workflow.dart';

/// The `to` node of the single outgoing edge of [from] labeled [label], or a
/// thrown assertion if no such edge exists. Used to assert verdict-labeled
/// routing in the seed graph.
String edgeTo(Graph g, String from, String label) {
  final e = g.outgoing(from).firstWhere(
        (e) => e.label == label,
        orElse: () => throw StateError(
            'no edge from "$from" labeled "$label" '
            '(have: ${g.outgoing(from).map((e) => e.label).toList()})'),
      );
  return e.to;
}

/// A scripted codergen backend for the end-to-end seed test: each node id maps
/// to a fixed response. A trailing `VERDICT: <label>` line is parsed into an
/// outcome (mirroring [TinaCodergenBackend]'s convention) so the engine routes
/// on it. Records each call's prompt + preamble for assertions.
class _ScriptedBackend implements CodergenBackend {
  final Map<String, String> scripted;
  _ScriptedBackend(this.scripted);

  final List<({String nodeId, String prompt, String preamble})> calls = [];

  /// Per-node call counter, so a test can vary behavior on repeat visits
  /// (e.g. a reviewer that clarifies once, then approves).
  final Map<String, int> _counts = {};
  CodergenResult? Function(String nodeId, int nthCall)? perCall;

  @override
  Future<CodergenResult> run({
    required PipelineNode node,
    required String prompt,
    required String preamble,
    required Context context,
    Future<void>? cancelSignal,
  }) async {
    calls.add((nodeId: node.id, prompt: prompt, preamble: preamble));
    final n = _counts[node.id] = (_counts[node.id] ?? 0) + 1;
    final override = perCall?.call(node.id, n);
    if (override != null) return override;
    final text = scripted[node.id] ?? 'response for ${node.id}';
    final verdict = _parseVerdict(text);
    return verdict == null
        ? CodergenResult(text)
        : CodergenResult(text,
            outcome: Outcome.success(preferredLabel: verdict));
  }
}

String? _parseVerdict(String text) {
  final lines = text.trimRight().split('\n');
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) return null;
  final m = RegExp(r'VERDICT:\s*([A-Za-z0-9_\-]+)', caseSensitive: false)
      .firstMatch(lines.last);
  return m?.group(1)?.toLowerCase();
}

/// An interviewer that is never expected to be asked (the seed's happy path
/// does not reach the human gate). If asked, it cancels — which fails the run,
/// surfacing an accidental gate hit.
class _UnexpectedGateInterviewer implements Interviewer {
  @override
  Future<Answer> ask(Question question) async => const Answer.cancelled();

  @override
  Future<void> inform(String message, {String? stage}) async {}
}

/// An interviewer that always picks the first option (mirroring the headless
/// auto-approve path) and records how many times it was asked.
class _PickFirstInterviewer implements Interviewer {
  int asked = 0;
  @override
  Future<Answer> ask(Question question) async {
    asked++;
    final options = question.options ?? const <Option>[];
    if (options.isEmpty) return const Answer.cancelled();
    final first = options.first;
    return Answer(value: first.key, selectedOption: first);
  }

  @override
  Future<void> inform(String message, {String? stage}) async {}
}

void main() {
  group('resolveDefaultWorkflowName', () {
    late Directory tmp;
    late Directory workflows;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_defwf_');
      workflows = Directory(p.join(tmp.path, 'workflows'));
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    void write(String name, String source) =>
        File(p.join(workflows.path, '$name.dot')).writeAsStringSync(source);

    test('null when the workflows dir is missing', () {
      expect(
          resolveDefaultWorkflowName(
              configured: null, workflowsDir: workflows),
          isNull);
    });

    test('default.dot present -> "default"', () {
      workflows.createSync(recursive: true);
      write('default', 'digraph d {}');
      expect(
          resolveDefaultWorkflowName(
              configured: null, workflowsDir: workflows),
          'default');
      expect(
          resolveDefaultWorkflowName(
              configured: '', workflowsDir: workflows),
          'default');
    });

    test('configured "none" disables even when default.dot exists', () {
      workflows.createSync(recursive: true);
      write('default', 'digraph d {}');
      expect(
          resolveDefaultWorkflowName(
              configured: 'none', workflowsDir: workflows),
          isNull);
    });

    test('configured name requires that file to exist', () {
      workflows.createSync(recursive: true);
      write('foo', 'digraph f {}');
      expect(
          resolveDefaultWorkflowName(
              configured: 'foo', workflowsDir: workflows),
          'foo');
      expect(
          resolveDefaultWorkflowName(
              configured: 'bar', workflowsDir: workflows),
          isNull);
    });
  });

  group('formatChatHistory', () {
    test('renders user/assistant text lines, oldest first', () {
      final h = [
        const Message(role: Role.user, content: [TextBlock('hi')]),
        const Message(role: Role.assistant, content: [TextBlock('hello')]),
      ];
      expect(formatChatHistory(h), 'user: hi\n\nassistant: hello');
    });

    test('skips tool blocks and empty text', () {
      final h = [
        const Message(role: Role.assistant, content: [
          TextBlock(''),
          ToolUseBlock(id: 't1', name: 'read', input: {'path': 'x'}),
          TextBlock('done'),
        ]),
      ];
      expect(formatChatHistory(h), 'assistant: done');
    });

    test('keeps the newest messages once the cap is hit', () {
      final h = [
        Message(role: Role.user, content: [TextBlock('oldest ' * 1000)]),
        const Message(role: Role.user, content: [TextBlock('newest')]),
      ];
      expect(formatChatHistory(h, maxChars: 100), 'user: newest');
    });

    test('newest message always included, head-trimmed when oversized', () {
      final h = [
        Message(role: Role.user, content: [TextBlock('x' * 5000)]),
      ];
      final out = formatChatHistory(h, maxChars: 100);
      expect(out.startsWith('user: '), isTrue);
      expect(out.length, 101); // 100 chars + '…' (label included in the block)
      expect(out.endsWith('…'), isTrue);
    });

    test('empty history -> empty string', () {
      expect(formatChatHistory(const []), '');
    });
  });

  group('seedDefaultWorkflow', () {
    late Directory tmp;
    late Directory workflows;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_seed_');
      workflows = Directory(p.join(tmp.path, 'workflows'));
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('creates the dir + default.dot; second call is a no-op', () {
      expect(seedDefaultWorkflow(workflows), isTrue);
      expect(
          File(p.join(workflows.path, 'default.dot')).existsSync(), isTrue);
      expect(seedDefaultWorkflow(workflows), isFalse);
    });

    test('seed parses and validates cleanly (no errors or warnings)', () {
      seedDefaultWorkflow(workflows);
      final source =
          File(p.join(workflows.path, 'default.dot')).readAsStringSync();
      final graph = parseDot(source);
      final diags = validate(graph);
      expect(diags.where((d) => d.severity == Severity.error), isEmpty);
      expect(diags.where((d) => d.severity == Severity.warning), isEmpty);
    });

    test('seed graph has the full review-then-parallel-execute shape', () {
      seedDefaultWorkflow(workflows);
      final source =
          File(p.join(workflows.path, 'default.dot')).readAsStringSync();
      final graph = parseDot(source);

      // Every node the workflow spec requires is present.
      expect(
          graph.nodes.keys,
          containsAll([
            'start', 'main', 'plan',
            'plan_review_1', 'plan_review_2', 'clarify',
            'fanout', 'exec_1', 'exec_2', 'exec_3', 'fanin',
            'exec_reviewer', 'done',
          ]));
      expect(graph.findStartNode()!.id, 'start');
      expect(graph.isTerminal(graph.node('done')!), isTrue);

      // Backbone: start -> main -> plan -> first review.
      expect(graph.outgoing('start').single.to, 'main');
      expect(graph.outgoing('main').single.to, 'plan');
      expect(graph.outgoing('plan').single.to, 'plan_review_1');

      // Two fresh passes of the SAME reviewer identity (the double review):
      // each node visit is already a fresh one-shot agent, so two sequential
      // nodes with one identity is the simplest expression of "review twice".
      expect(graph.node('plan_review_1')!.systemPrompt,
          graph.node('plan_review_2')!.systemPrompt);
      expect(graph.node('plan_review_1')!.systemPrompt, isNotEmpty);
      // Approve: pass 1 -> pass 2 -> fan-out. Revise: a fresh pass of the
      // same node (the reviewer updates the plan itself, so revise loops to a
      // fresh review, not back to the plan node).
      expect(edgeTo(graph, 'plan_review_1', 'approve'), 'plan_review_2');
      expect(edgeTo(graph, 'plan_review_2', 'approve'), 'fanout');
      expect(edgeTo(graph, 'plan_review_1', 'revise'), 'plan_review_1');
      expect(edgeTo(graph, 'plan_review_2', 'revise'), 'plan_review_2');
      // Clarification goes through a human gate.
      expect(edgeTo(graph, 'plan_review_1', 'clarify'), 'clarify');
      expect(graph.node('clarify')!.shape, 'hexagon');
      expect(graph.outgoing('clarify').map((e) => e.to).toList(),
          contains('plan_review_1'));

      // Parallel fan-out (component) -> executors -> fan-in (tripleoctagon).
      expect(graph.node('fanout')!.shape, 'component');
      expect(graph.node('fanin')!.shape, 'tripleoctagon');
      final fanoutTargets =
          graph.outgoing('fanout').map((e) => e.to).toSet();
      expect(fanoutTargets,
          containsAll(['exec_1', 'exec_2', 'exec_3', 'fanin']));

      // Fan-in -> execution reviewer -> done.
      expect(graph.outgoing('fanin').single.to, 'exec_reviewer');
      expect(graph.outgoing('exec_reviewer').single.to, 'done');

      // Every working node carries its own identity.
      for (final id in [
        'main',
        'plan',
        'plan_review_1',
        'exec_1',
        'exec_reviewer'
      ]) {
        expect(graph.node(id)!.systemPrompt, isNotEmpty,
            reason: '$id missing system_prompt');
      }
    });

    test('seed runs end-to-end: two reviews approve, work fans out, '
        'results are reviewed', () async {
      seedDefaultWorkflow(workflows);
      final source =
          File(p.join(workflows.path, 'default.dot')).readAsStringSync();
      final graph = parseDot(source);

      final backend = _ScriptedBackend({
        'main': 'findings: the bug is in foo.dart',
        'plan': 'plan with chunks [1] [2] [3]',
        'plan_review_1': 'looks good\nVERDICT: approve',
        'plan_review_2': 'still good\nVERDICT: approve',
        'exec_1': 'did chunk 1',
        'exec_2': 'did chunk 2',
        'exec_3': 'did chunk 3',
        'exec_reviewer': 'all chunks done',
      });
      final store = MemoryRunStore();
      final codergen = CodergenHandler(backend);
      final registry = NodeHandlerRegistry()
        ..register('start', StartHandler())
        ..register('exit', ExitHandler())
        ..register('conditional', ConditionalHandler())
        ..register('codergen', codergen)
        ..register('wait.human', HumanGateHandler(_UnexpectedGateInterviewer()));
      registry.register('parallel', ParallelHandler(registry));
      registry.register('parallel.fan_in', ParallelFanInHandler());
      registry.defaultHandler = codergen;

      final engine = PipelineEngine(
        graph: graph,
        registry: registry,
        runStore: store,
        runId: 'r1',
        workflowName: 'default',
        backoffFor: (_) => Duration.zero,
      );
      final outcome = await engine.run(
          input: 'fix the bug', seedContext: {'history': 'user: hi'});

      expect(outcome.status, StageStatus.success);
      // Backbone order: plan -> review pass 1 -> review pass 2 -> fan-out.
      final order = store.nodes.map((n) => n.nodeId).toList();
      expect(order.indexOf('plan_review_2'), greaterThan(order.indexOf('plan')));
      expect(order.indexOf('plan_review_2'),
          greaterThan(order.indexOf('plan_review_1')));
      expect(order.indexOf('fanout'), greaterThan(order.indexOf('plan_review_2')));
      // All three executors ran (in parallel; their relative order is free).
      for (final id in ['exec_1', 'exec_2', 'exec_3']) {
        expect(store.nodes.any((n) => n.nodeId == id), isTrue, reason: id);
      }
      // The execution reviewer ran after the fan-in and saw the merged result.
      expect(order.indexOf('exec_reviewer'), greaterThan(order.indexOf('fanin')));
      expect(
          backend.calls
              .firstWhere((c) => c.nodeId == 'exec_reviewer')
              .preamble,
          allOf(contains('did chunk 1'), contains('did chunk 2'),
              contains('did chunk 3')));
      // $input was expanded into the main node's prompt.
      expect(backend.calls.firstWhere((c) => c.nodeId == 'main').prompt,
          contains('fix the bug'));
    });

    test('clarify verdict routes through the human gate and back to a review',
        () async {
      seedDefaultWorkflow(workflows);
      final source =
          File(p.join(workflows.path, 'default.dot')).readAsStringSync();
      final graph = parseDot(source);

      final backend = _ScriptedBackend({
        'main': 'findings',
        'plan': 'plan [1] [2] [3]',
        'plan_review_1': 'approved\nVERDICT: approve',
        'plan_review_2': 'approved\nVERDICT: approve',
        'exec_1': 'did chunk 1',
        'exec_2': 'did chunk 2',
        'exec_3': 'did chunk 3',
        'exec_reviewer': 'all chunks done',
      });
      // On its FIRST visit, pass 1 asks for clarification; on every later
      // visit it approves (the scripted default).
      backend.perCall = (id, n) {
        if (id == 'plan_review_1' && n == 1) {
          return CodergenResult('I need a decision from the user\nVERDICT: clarify',
              outcome: const Outcome.success(preferredLabel: 'clarify'));
        }
        return null;
      };
      final interviewer = _PickFirstInterviewer();

      final store = MemoryRunStore();
      final codergen = CodergenHandler(backend);
      final registry = NodeHandlerRegistry()
        ..register('start', StartHandler())
        ..register('exit', ExitHandler())
        ..register('conditional', ConditionalHandler())
        ..register('codergen', codergen)
        ..register('wait.human', HumanGateHandler(interviewer));
      registry.register('parallel', ParallelHandler(registry));
      registry.register('parallel.fan_in', ParallelFanInHandler());
      registry.defaultHandler = codergen;
      final engine = PipelineEngine(
        graph: graph,
        registry: registry,
        runStore: store,
        runId: 'r1',
        workflowName: 'default',
        backoffFor: (_) => Duration.zero,
      );
      final outcome = await engine.run(input: 'fix the bug');

      expect(outcome.status, StageStatus.success);
      // The human gate was asked exactly once...
      expect(interviewer.asked, 1);
      // ...and routing resumed at plan_review_1 (the gate's first option),
      // which then approved and continued: plan_review_1 ran twice.
      final review1Runs =
          store.nodes.where((n) => n.nodeId == 'plan_review_1').length;
      expect(review1Runs, 2);
      // The clarify gate node itself ran.
      expect(store.nodes.any((n) => n.nodeId == 'clarify'), isTrue);
      // And the run still reached execution.
      expect(store.nodes.any((n) => n.nodeId == 'fanout'), isTrue);
    });
  });

  group('ensureDefaultWorkflowUsable', () {
    late Directory tmp;
    late Directory workflows;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_usbl_');
      workflows =
          Directory(p.join(tmp.path, 'workflows'))..createSync(recursive: true);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Future<void> write(String name, String source) =>
        File(p.join(workflows.path, '$name.dot')).writeAsString(source);

    test('valid file passes', () async {
      await write('ok', kDefaultWorkflowDotSource);
      await ensureDefaultWorkflowUsable(workflows, 'ok');
    });

    test('missing file throws', () {
      expect(() => ensureDefaultWorkflowUsable(workflows, 'nope'),
          throwsA(isA<DefaultWorkflowUnusable>()));
    });

    test('unparseable source throws', () async {
      await write('bad', 'digraph {');
      await expectLater(ensureDefaultWorkflowUsable(workflows, 'bad'),
          throwsA(isA<DefaultWorkflowUnusable>()));
    });

    test('validation error (no terminal node) throws', () async {
      await write('noexit', 'digraph e { start [shape=Mdiamond] }');
      await expectLater(ensureDefaultWorkflowUsable(workflows, 'noexit'),
          throwsA(isA<DefaultWorkflowUnusable>()));
    });
  });
}
