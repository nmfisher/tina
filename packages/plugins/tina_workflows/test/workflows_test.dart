// The workflows plugin: the catalog (files shadow entries, the list is the
// on-disk scan), the name guard, the seed graph, and the run — nodes as real
// turns on the session's loop, the outcome as one WorkflowRunEntry through
// recordState, so the last run survives a store round trip. The gate asks on
// the Terminal; a cancelled run records no verdict.
//
// Run: dart test
library;

import 'package:tina_persistence/tina_persistence.dart';
import 'dart:async';
import 'dart:io';

import 'package:attractor/attractor.dart' show parseDot, Severity, validate;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_workflows/tina_workflows.dart';
import 'package:test/test.dart';

final class _CaptureTerminal implements Terminal {
  final lines = <String>[];
  final answers = <String>[];

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) async =>
      answers.isEmpty ? '' : answers.removeAt(0);
}

(AgentLoop, WorkflowsPlugin) _wired({
  required Directory tinaDir,
  ScriptedProvider? provider,
  Terminal? terminal,
  WorkflowsPlugin? plugin,
  NodeTurnRunner? runNodeTurn,
}) {
  final p0 = provider ?? ScriptedProvider([]);
  final p = plugin ??
      WorkflowsPlugin(
          tinaDir: tinaDir, terminal: terminal, runNodeTurn: runNodeTurn);
  final loop = AgentLoop(provider: p0, plugins: [p]);
  p.mountOn(loop);
  return (loop, p);
}

/// The tiny linear graph the node-turn tests run: start → a → b → done.
const _linearDot = '''
digraph tiny {
  start [shape=Mdiamond]
  a [shape=box, prompt="Do A with \$input"]
  b [shape=box, prompt="Do B with \$a", context="a"]
  done [shape=Msquare]
  start -> a
  a -> b
  b -> done
}
''';

/// start → reviewer (VERDICT routes) → done / revise-loop.
const _verdictDot = '''
digraph routed {
  start [shape=Mdiamond]
  reviewer [shape=box, prompt="Review \$input; end with VERDICT: approve"]
  done [shape=Msquare]
  start -> reviewer
  reviewer -> done [label="approve"]
  reviewer -> reviewer [label="revise"]
}
''';

void main() {
  late Directory tina;
  setUp(() async {
    tina = await Directory.systemTemp.createTemp('tina_wf_tina_');
    addTearDown(() => tina.deleteSync(recursive: true));
  });

  group('name hygiene', () {
    test('the old guard, verbatim', () {
      expect(isSafeWorkflowName('default'), isTrue);
      expect(isSafeWorkflowName(' my-flow '), isTrue);
      expect(isSafeWorkflowName(''), isFalse);
      expect(isSafeWorkflowName('../evil'), isFalse);
      expect(isSafeWorkflowName('a/b'), isFalse);
      expect(isSafeWorkflowName(r'a\b'), isFalse);
      expect(isSafeWorkflowName('..'), isFalse);
      expect(isSafeWorkflowName('a\x00b'), isFalse);
    });

    test('normalize drops a typed .dot suffix', () {
      expect(normalizeWorkflowName(' default.dot '), 'default');
      expect(normalizeWorkflowName('..dot'), isNull);
      expect(normalizeWorkflowName(''), isNull);
    });
  });

  group('catalog', () {
    test('files shadow entries; list is the on-disk scan only', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/default.dot').writeAsStringSync(_linearDot);
      File('${dir.path}/zeta.dot').writeAsStringSync(_linearDot);

      final catalog = WorkflowCatalog.standard(workflowsDir: dir);
      expect(catalog.list(), ['default', 'zeta']);

      // The file wins over the built-in entry of the same name.
      expect(await catalog.read('default'), _linearDot);

      // A registered entry answers only where no file does.
      catalog.register('omega', _verdictDot);
      expect(await catalog.read('omega'), _verdictDot);
      // ...and never appears in the list.
      expect(catalog.list(), ['default', 'zeta']);
    });

    test(
        'seeding writes default.dot once; deleting it falls back to '
        'the built-in entry only when the dir still exists', () async {
      final dir = Directory('${tina.path}/workflows');
      expect(seedDefaultWorkflow(dir), isTrue);
      expect(seedDefaultWorkflow(dir), isFalse, reason: 'idempotent');
      final catalog = WorkflowCatalog.standard(workflowsDir: dir);
      expect(catalog.list(), ['default']);
      final seeded = await catalog.read('default');
      expect(seeded, contains('digraph default'));
      // The seed parses and validates — the file IS the launchable graph.
      final prepared = parseDot(seeded);
      final problems =
          validate(prepared).where((d) => d.severity == Severity.error);
      expect(problems, isEmpty);

      // Deleting the file returns to the empty list — the entry is a
      // resolution fallback, not a list item.
      File('${dir.path}/default.dot').deleteSync();
      expect(WorkflowCatalog.standard(workflowsDir: dir).list(), isEmpty);
    });

    test('read refuses a name that would escape the dir', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      final catalog = WorkflowCatalog.standard(workflowsDir: dir);
      expect(
        () => catalog.read('../evil'),
        throwsA(isA<FileSystemException>()
            .having((e) => e.message, 'message', workflowNameRejection)),
      );
    });
  });

  group('prepare', () {
    test('a missing workflow names it', () async {
      final (loop, plugin) = _wired(tinaDir: tina);
      expect(loop, isNotNull);
      expect(
        plugin.prepare('nope'),
        throwsA(isA<WorkflowProblem>().having((e) => e.message, 'message',
            contains('workflow "nope": workflow not found'))),
      );
    });

    test('invalid DOT says so; invalid graphs list the errors', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/broken.dot')
          .writeAsStringSync('digraph x { start [shape=Mdiamond] ');
      File('${dir.path}/lost.dot')
          .writeAsStringSync('digraph x { a [shape=box] }');
      final plugin = WorkflowsPlugin(tinaDir: tina);
      expect(
        plugin.prepare('broken'),
        throwsA(isA<WorkflowProblem>()
            .having((e) => e.message, 'message', contains('not valid DOT'))),
      );
      expect(
        plugin.prepare('lost'),
        throwsA(isA<WorkflowProblem>()
            .having((e) => e.message, 'message', contains('is invalid'))),
      );
    });
  });

  group('run', () {
    test(
        'a linear graph runs one turn per node; the entry records the '
        'nodes and the run survives a derive', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/tiny.dot').writeAsStringSync(_linearDot);
      final provider = ScriptedProvider([
        scriptedReply('A did its thing'),
        scriptedReply('B saw: A did its thing'),
      ]);
      final (loop, plugin) = _wired(tinaDir: tina, provider: provider);
      final terminal = _CaptureTerminal();
      await plugin.run(name: 'tiny', terminal: terminal);

      // One turn per LLM node, on the session's loop: the log carries
      // the node turns like any turn.
      expect(provider.callCount, 2);
      final turnInputs =
          loop.log.whereType<InputRecordedEntry>().map((e) => e.text).toList();
      expect(turnInputs, hasLength(2));
      expect(turnInputs[0], contains('Do A with'));
      // The second node's preamble carries the first node's output.
      expect(turnInputs[1], contains('A did its thing'));
      expect(turnInputs[1], contains('Do B with'));

      final run = loop.log
          .whereType<PluginStateEntry>()
          .where(WorkflowRunEntry.matches)
          .map(WorkflowRunEntry.decode)
          .single;
      expect(run.workflow, 'tiny');
      expect(run.status, WorkflowRunEntry.statusSuccess);
      // start/a/b dispatch handlers; `done` is the graph's terminal and
      // the engine exits before dispatching it.
      expect(run.nodes, ['start', 'a', 'b']);
      expect(run.detail, 'B saw: A did its thing');

      // Derive reports it — the same fact a resume replays.
      expect(loop.derive().workflowRun!.status, WorkflowRunEntry.statusSuccess);
      expect(plugin.lastRun!.workflow, 'tiny');
      expect(
          terminal.lines,
          containsAllInOrder([
            contains('▶ workflow tiny'),
            contains('▶ a'),
            contains('✔ recorded: tiny succeeded'),
          ]));
    });

    test('a VERDICT line routes the next edge', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/routed.dot').writeAsStringSync(_verdictDot);
      final provider = ScriptedProvider([
        scriptedReply('looks good to me\nVERDICT: approve'),
      ]);
      final (loop, _) = _wired(tinaDir: tina, provider: provider);
      final plugin = WorkflowsPlugin(tinaDir: tina, seedOnMount: false);
      plugin.mountOn(loop);
      await plugin.run(name: 'routed', terminal: _CaptureTerminal());

      expect(provider.callCount, 1, reason: 'approve ends the run');
      final run = loop.log
          .whereType<PluginStateEntry>()
          .where(WorkflowRunEntry.matches)
          .map(WorkflowRunEntry.decode)
          .single;
      expect(run.status, WorkflowRunEntry.statusSuccess);
      expect(run.nodes, ['start', 'reviewer']);
    });

    test('a failing node turn fails the run; the failure is recorded',
        () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/tiny.dot').writeAsStringSync(_linearDot);
      final provider = ScriptedProvider([
        [const StreamError('provider exploded')],
      ]);
      final (loop, plugin) = _wired(tinaDir: tina, provider: provider);
      await plugin.run(name: 'tiny', terminal: _CaptureTerminal());

      final run = loop.log
          .whereType<PluginStateEntry>()
          .where(WorkflowRunEntry.matches)
          .map(WorkflowRunEntry.decode)
          .single;
      expect(run.status, WorkflowRunEntry.statusFailed);
      expect(run.detail, contains('node "a" failed'));
      expect(loop.derive().workflowRun!.status, WorkflowRunEntry.statusFailed);
    });

    test('a cancelled node turn records nothing', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/tiny.dot').writeAsStringSync(_linearDot);
      final provider = ScriptedProvider([]);
      final (loop, plugin) = _wired(
          tinaDir: tina,
          provider: provider,
          runNodeTurn: (loop, nodeTurn) async {
            throw WorkflowCancelled(nodeTurn.nodeId);
          });
      await plugin.run(name: 'tiny', terminal: _CaptureTerminal());

      expect(
          loop.log
              .whereType<PluginStateEntry>()
              .where(WorkflowRunEntry.matches)
              .map(WorkflowRunEntry.decode),
          isEmpty,
          reason: 'the user stopping the session is no verdict');
      expect(loop.derive().workflowRun, isNull);
    });

    test(
        'an unsupported node type (parallel) fails the run with a clear '
        'reason instead of fanning out', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/par.dot').writeAsStringSync('''
digraph par {
  start [shape=Mdiamond]
  split [shape=component]
  done [shape=Msquare]
  start -> split
  split -> done
}
''');
      final (loop, plugin) =
          _wired(tinaDir: tina, runNodeTurn: (loop, nodeTurn) async => 'x');
      await plugin.run(name: 'par', terminal: _CaptureTerminal());

      final run = loop.log
          .whereType<PluginStateEntry>()
          .where(WorkflowRunEntry.matches)
          .map(WorkflowRunEntry.decode)
          .single;
      expect(run.status, WorkflowRunEntry.statusFailed);
      expect(run.detail, contains('does not support'));
    });

    test('the human gate asks on the terminal and routes the answer', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/gated.dot').writeAsStringSync('''
digraph gated {
  start [shape=Mdiamond]
  gate [shape=hexagon, prompt="Proceed?"]
  done [shape=Msquare]
  start -> gate
  gate -> done [label="[Y] Yes, continue"]
  gate -> gate [label="[N] No, again"]
}
''');
      final (loop, plugin) =
          _wired(tinaDir: tina, runNodeTurn: (loop, nodeTurn) async => 'x');
      final terminal = _CaptureTerminal()..answers.add('y');
      await plugin.run(name: 'gated', terminal: terminal);

      expect(terminal.lines.join('\n'), contains('? Proceed?'));
      expect(terminal.lines.join('\n'), contains('[Y] Yes, continue'));
      final run = loop.log
          .whereType<PluginStateEntry>()
          .where(WorkflowRunEntry.matches)
          .map(WorkflowRunEntry.decode)
          .single;
      expect(run.status, WorkflowRunEntry.statusSuccess);
      expect(run.nodes, ['start', 'gate']);
    });

    test('an empty gate answer fails the run', () async {
      final dir = Directory('${tina.path}/workflows')..createSync();
      File('${dir.path}/gated.dot').writeAsStringSync('''
digraph gated {
  start [shape=Mdiamond]
  gate [shape=hexagon]
  done [shape=Msquare]
  start -> gate
  gate -> done [label="[Y] Yes"]
  gate -> gate [label="[N] No"]
}
''');
      final (loop, plugin) =
          _wired(tinaDir: tina, runNodeTurn: (loop, nodeTurn) async => 'x');
      await plugin.run(name: 'gated', terminal: _CaptureTerminal());

      final run = loop.log
          .whereType<PluginStateEntry>()
          .where(WorkflowRunEntry.matches)
          .map(WorkflowRunEntry.decode)
          .single;
      expect(run.status, WorkflowRunEntry.statusFailed);
    });
  });

  group('surfaces', () {
    test(
        'the <workflows> section lists what is on disk; no files, no '
        'section', () {
      final plugin = WorkflowsPlugin(tinaDir: tina, seedOnMount: false);
      final ctx = TurnContext(
        CancelToken(),
        input: const Input('probe', id: 'probe'),
        pinnedTools: const [],
        messages: const [],
        promptSections: [],
      );
      plugin.onPrompt(ctx);
      expect(ctx.promptSections, isEmpty);

      Directory('${tina.path}/workflows').createSync();
      File('${tina.path}/workflows/tiny.dot').writeAsStringSync(_linearDot);
      final ctx2 = TurnContext(
        CancelToken(),
        input: const Input('probe', id: 'probe'),
        pinnedTools: const [],
        messages: const [],
        promptSections: [],
      );
      plugin.onPrompt(ctx2);
      expect(ctx2.promptSections.single, startsWith('<workflows>'));
      expect(ctx2.promptSections.single, contains('tiny'));
      expect(ctx2.promptSections.single, contains('/workflow run <name>'));
    });

    test('/workflow lists, shows and reports the last run', () async {
      final terminal = _CaptureTerminal();
      // The fake node reply ends with the VERDICT line the seed's
      // reviewer prompts ask for — the real model's, per the prompts.
      final (loop, plugin) = _wired(
          tinaDir: tina,
          terminal: terminal,
          runNodeTurn: (loop, nodeTurn) async =>
              'node said this\nVERDICT: approve');
      expect(loop, isNotNull);

      final cmd = plugin.commands.single;
      await cmd.handler('');
      expect(terminal.lines.join('\n'), contains('workflows:'));
      expect(terminal.lines.join('\n'), contains('default'));

      terminal.lines.clear();
      await cmd.handler('show default');
      await _drain();
      expect(terminal.lines.join('\n'), contains('workflow default —'));
      expect(terminal.lines.join('\n'), contains('plan_review_1: codergen'));

      terminal.lines.clear();
      await cmd.handler('last');
      expect(terminal.lines.single, contains('no workflow run recorded'));

      // A run through the command records, and `last` reports it. The
      // command's future is fire-and-forget (`unawaited`); drain it.
      terminal.lines.clear();
      await cmd.handler('run default fix the flaky parser test');
      await _drain();
      final run = loop.log
          .whereType<PluginStateEntry>()
          .where(WorkflowRunEntry.matches)
          .map(WorkflowRunEntry.decode)
          .last;
      expect(run.workflow, 'default');
      expect(loop.derive().workflowRun, isNotNull);

      terminal.lines.clear();
      await cmd.handler('last');
      expect(terminal.lines.join('\n'), contains('last run: default'));
    });

    test('/workflow run rejects an unsafe name and a missing workflow',
        () async {
      final terminal = _CaptureTerminal();
      final (loop, plugin) = _wired(tinaDir: tina, terminal: terminal);
      expect(loop, isNotNull);
      final cmd = plugin.commands.single;

      await cmd.handler('run ../evil');
      expect(terminal.lines.single, workflowNameRejection);

      terminal.lines.clear();
      await cmd.handler('run ghost');
      await _drain();
      expect(terminal.lines.join('\n'),
          contains('workflow "ghost": workflow not found'));
      expect(
          loop.log
              .whereType<PluginStateEntry>()
              .where(WorkflowRunEntry.matches)
              .map(WorkflowRunEntry.decode),
          isEmpty);
    });
  });

  group('resume', () {
    test('the last run survives a store round trip', () async {
      final ws = await Directory.systemTemp.createTemp('tina_wf_ws_');
      addTearDown(() => ws.deleteSync(recursive: true));
      final storePath = '${ws.path}/session.db';

      final tinaDir = Directory('${ws.path}/tina');
      // The fake node replies end with the VERDICT line the seed's
      // reviewer prompts ask the model for.
      final startedPlugin = WorkflowsPlugin(
          tinaDir: tinaDir,
          runNodeTurn: (loop, nodeTurn) async => 'wrote it\nVERDICT: approve');
      final started = Host.start(HostConfig(
        providerFactory: (_) => ScriptedProvider([]),
        workingDirectory: ws.path,
        plugins: [
          startedPlugin,
          PersistencePlugin(openStore: () => SessionStore.open(storePath)),
        ],
      ));
      await startedPlugin.run(name: 'default', terminal: _CaptureTerminal());
      final sessionId = started.session.id;
      started.close();

      final resumed = Host.resume(
        HostConfig(
          providerFactory: (_) => ScriptedProvider([]),
          workingDirectory: ws.path,
          plugins: [
            WorkflowsPlugin(tinaDir: tinaDir),
            PersistencePlugin(openStore: () => SessionStore.open(storePath)),
          ],
        ),
        sessionId,
      );
      final view = resumed.session.loop.derive();
      expect(view.workflowRun, isNotNull);
      expect(view.workflowRun!.workflow, 'default');
      expect(view.workflowRun!.status, WorkflowRunEntry.statusSuccess);
      resumed.close();
    });
  });
}

/// Settle the run's fire-and-forget command future.
Future<void> _drain() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
