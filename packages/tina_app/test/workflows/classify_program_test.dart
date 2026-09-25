import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tina_app/src/workflows/classify_program.dart';

/// The classifier-program seam (docs/proposals/hierarchical_classifiers.md,
/// implementation slice 2+3): DOT programs load from the workspace, validate
/// structurally and per-stage, and the built-in program is the never-missing
/// fallback for `/index`.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('tina_program_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory programsDir() {
    final dir = Directory(p.join(tmp.path, '.tina', 'programs'))
      ..createSync(recursive: true);
    return dir;
  }

  File writeProgram(String name, String source, {Directory? inDir}) {
    final dir = inDir ?? programsDir();
    final file = File(p.join(dir.path, name));
    file.writeAsStringSync(source);
    return file;
  }

  const minimalProgram = '''
digraph custom {
  start [shape=Mdiamond];
  language [type="classify"];
  exit [shape=Msquare];
  start -> language;
  language -> exit;
}
''';

  group('built-in program', () {
    test('is valid with the default stage set', () {
      final program = builtinIndexProgram();

      expect(program.valid, isTrue, reason: program.errorsText);
      expect(program.origin, 'builtin');
      expect(program.name, 'index');
    });

    test('sequences start → language → details → exit', () {
      final graph = builtinIndexProgram().graph;

      expect(
        graph.nodes.keys,
        containsAll(['start', 'language', 'details', 'exit']),
      );
      expect(graph.findStartNode()?.id, 'start');
      expect(graph.terminalNodes.single.id, 'exit');
      // Unconditional default edge: details runs after any non-failed stage.
      expect(
        graph.edges.any(
          (e) =>
              e.from == 'language' && e.to == 'details' && e.condition.isEmpty,
        ),
        isTrue,
      );
    });

    test('a failed language stage ends the run without a recovery edge', () {
      final graph = builtinIndexProgram().graph;
      // No conditional (recovery) edges on language: the engine's fail rule
      // takes no unconditional edge, so a hard failure finishes the run as
      // failed and details is skipped. An explicit outcome=fail edge to exit
      // would *recover* into an exit-success run instead (attractor
      // engine_test: "failed node can take explicit recovery edge").
      expect(graph.outgoing('language').where((e) => e.hasCondition), isEmpty);
      expect(graph.outgoing('language').single.to, 'details');
    });
  });

  group('stage validation', () {
    test('accepts classify nodes naming a known stage', () {
      final program = parseClassifyProgram('ok', '''
digraph ok {
  start [shape=Mdiamond];
  language [type="classify", stage="details"];
  exit [shape=Msquare];
  start -> language;
  language -> exit;
}
''', origin: 'test');

      expect(program.valid, isTrue, reason: program.errorsText);
    });

    test('rejects an unknown stage name with an error diagnostic', () {
      final program = parseClassifyProgram('bad_stage', '''
digraph bad {
  start [shape=Mdiamond];
  lang [type="classify", stage="langauge"];
  exit [shape=Msquare];
  start -> lang;
  lang -> exit;
}
''', origin: 'test');

      expect(program.valid, isFalse);
      final diag = program.diagnostics.singleWhere(
        (d) => d.rule == 'classify_stage_known',
      );
      expect(diag.severity, Severity.error);
      expect(diag.message, contains('langauge'));
      expect(diag.message, contains('language, details'));
    });

    test('warns on a non-string stage attribute', () {
      final program = parseClassifyProgram('stage_int', '''
digraph stage_int {
  start [shape=Mdiamond];
  language [type="classify", stage=7];
  exit [shape=Msquare];
  start -> language;
  language -> exit;
}
''', origin: 'test');

      final diag = program.diagnostics.singleWhere(
        (d) => d.rule == 'classify_stage_attr',
      );
      expect(diag.severity, Severity.warning);
      // Still valid: the node id is used, and `language` is a known stage.
      expect(program.valid, isTrue, reason: program.errorsText);
    });
  });

  group('parse + structural validation', () {
    test('a parse failure becomes a dot_parse error diagnostic', () {
      final program = parseClassifyProgram(
        'broken',
        'not a dot graph {',
        origin: 'test',
      );

      expect(program.valid, isFalse);
      expect(program.diagnostics.any((d) => d.rule == 'dot_parse'), isTrue);
      expect(program.errorsText, contains('broken'));
    });

    test('merges attractor structural diagnostics', () {
      final program = parseClassifyProgram('structural', '''
digraph structural {
  start [shape=Mdiamond];
  language [type="classify"];
  orphan [type="classify", stage="language"];
  exit [shape=Msquare];
  start -> language;
  language -> exit;
}
''', origin: 'test');

      expect(program.valid, isFalse);
      // The declared-but-disconnected node is unreachable from the start.
      final diag = program.diagnostics.singleWhere(
        (d) => d.rule == 'reachability',
      );
      expect(diag.nodeId, 'orphan');
    });
  });

  group('loadIndexProgram precedence', () {
    test('falls back to the built-in program when nothing exists', () async {
      final program = await loadIndexProgram(
        workspaceRoot: tmp.path,
        globalWorkflowsDir: Directory(p.join(tmp.path, 'global')),
      );

      expect(program.origin, 'builtin');
      expect(program.valid, isTrue);
    });

    test('loads the workspace single program', () async {
      writeProgram('flutter_index.dot', minimalProgram);

      final program = await loadIndexProgram(workspaceRoot: tmp.path);

      expect(
        program.origin,
        endsWith(p.join('.tina', 'programs', 'flutter_index.dot')),
      );
      expect(program.name, 'flutter_index');
      expect(program.valid, isTrue, reason: program.errorsText);
    });

    test('prefers workspace index.dot over other programs', () async {
      writeProgram('other.dot', minimalProgram);
      writeProgram('index.dot', minimalProgram);

      final program = await loadIndexProgram(workspaceRoot: tmp.path);

      expect(program.name, 'index');
    });

    test(
      'falls back to the global index.dot when the workspace has none',
      () async {
        final global = Directory(p.join(tmp.path, 'workflows'))
          ..createSync(recursive: true);
        File(
          p.join(global.path, 'index.dot'),
        ).writeAsStringSync(minimalProgram);

        final program = await loadIndexProgram(
          workspaceRoot: tmp.path,
          globalWorkflowsDir: global,
        );

        expect(program.origin, endsWith(p.join('workflows', 'index.dot')));
        expect(program.name, 'index');
      },
    );

    test(
      'ambiguous workspace (several programs, no index) uses the built-in',
      () async {
        writeProgram('a.dot', minimalProgram);
        writeProgram('b.dot', minimalProgram);

        final program = await loadIndexProgram(workspaceRoot: tmp.path);

        expect(program.origin, 'builtin');
      },
    );

    test('returns an invalid file program as-is, never the fallback', () async {
      writeProgram('index.dot', 'broken {');

      final program = await loadIndexProgram(workspaceRoot: tmp.path);

      expect(program.valid, isFalse);
      expect(
        program.origin,
        endsWith(p.join('.tina', 'programs', 'index.dot')),
      );
      expect(program.errorsText, isNotEmpty);
    });
  });

  group('builtinIndexProgramDot', () {
    test('parses as a valid program with reader instructions', () {
      final dot = builtinIndexProgramDot();
      expect(dot, startsWith('// Classifier program for /index'));
      expect(dot, contains('/workflow edit index'));

      final program = parseClassifyProgram('index', dot, origin: 'review');
      expect(program.valid, isTrue, reason: program.errorsText);
      expect(
        program.graph.nodes.keys,
        containsAll(['start', 'language', 'details', 'exit']),
      );
    });

    test('round-trips through graphToDot unchanged (editor save cycle)', () {
      final graph = parseDot(builtinIndexProgramDot());
      final once = graphToDot(graph);
      final twice = graphToDot(parseDot(once));
      expect(twice, once, reason: 'the serializer is canonical');

      // Stage routing survives the rewrite the editor performs on save.
      final saved = parseClassifyProgram('index', once, origin: 'saved');
      expect(saved.valid, isTrue, reason: saved.errorsText);
      String edgeKey(Graph g) =>
          g.edges.map((e) => '${e.from}->${e.to}:${e.condition}').join(',');
      expect(edgeKey(saved.graph), edgeKey(graph));
    });

    test('echoes the review focus as a reader comment', () {
      expect(
        builtinIndexProgramDot(focus: ' deploy gates '),
        contains('// Review focus: deploy gates'),
      );
      expect(builtinIndexProgramDot(), isNot(contains('Review focus')));
    });
  });

  group('resolveWorkflowProgramFile', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('workflow-resolve-');
      addTearDown(() => root.delete(recursive: true));
    });

    test('prefers the workspace program over the global one', () {
      final ws = Directory('${root.path}/.tina/programs')
        ..createSync(recursive: true);
      File('${ws.path}/index.dot').writeAsStringSync('digraph index {}');
      final global = Directory('${root.path}/global')
        ..createSync(recursive: true);
      File('${global.path}/index.dot').writeAsStringSync('digraph index {}');

      final file = resolveWorkflowProgramFile(
        name: 'index',
        workspaceRoot: root.path,
        globalWorkflowsDir: global,
      );

      expect(file!.path, contains(p.join('.tina', 'programs')));
    });

    test('falls back to the global workflows dir, else null', () {
      final global = Directory('${root.path}/global')
        ..createSync(recursive: true);
      File(
        '${global.path}/default.dot',
      ).writeAsStringSync('digraph default {}');

      expect(
        resolveWorkflowProgramFile(
          name: 'default',
          workspaceRoot: root.path,
          globalWorkflowsDir: global,
        )!.path,
        contains(p.join('global', 'default.dot')),
      );
      expect(
        resolveWorkflowProgramFile(
          name: 'missing',
          workspaceRoot: root.path,
          globalWorkflowsDir: global,
        ),
        isNull,
      );
      expect(
        resolveWorkflowProgramFile(
          name: 'default',
          workspaceRoot: root.path,
          globalWorkflowsDir: null,
        ),
        isNull,
      );
    });
  });
}
