import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;

import 'classify_handler.dart';

/// The stage names the built-in index program may reference (decision 4 in
/// docs/proposals/hierarchical_classifiers.md: framework and tooling share one
/// `details` stage). Program files are validated against this set.
const kClassifyProgramStages = {'language', 'details'};

/// A classifier program: a parsed attractor graph plus its merged diagnostics
/// (attractor's structural validation + stage-name checks). [valid] is false
/// when any diagnostic is an error; the caller decides how to surface that —
/// an invalid program read from disk is returned as-is, never silently
/// replaced by the fallback.
class ClassifyProgram {
  final String name;

  /// `'builtin'` or the on-disk path the program was read from.
  final String origin;
  final Graph graph;
  final List<Diagnostic> diagnostics;

  const ClassifyProgram({
    required this.name,
    required this.origin,
    required this.graph,
    required this.diagnostics,
  });

  bool get valid => !diagnostics.any((d) => d.severity == Severity.error);

  /// All error diagnostics, newline-joined (empty when [valid]).
  String get errorsText =>
      diagnostics
          .where((d) => d.severity == Severity.error)
          .map((d) => '  $d')
          .join('\n');
}

/// Structural validation (attractor) plus program rules: every
/// `type="classify"` node must resolve to a stage in [stages], and a `stage`
/// attribute must be a string (a non-string silently falls back to the node
/// id at run time, which is never what the author meant).
List<Diagnostic> validateClassifyProgram(
  Graph graph,
  Set<String> stages,
) {
  final diags = <Diagnostic>[];
  for (final node in graph.nodes.values) {
    if (node.type != 'classify') continue;
    final raw = node.attrs['stage'];
    if (raw != null && raw is! String) {
      diags.add(
        Diagnostic(
          rule: 'classify_stage_attr',
          severity: Severity.warning,
          nodeId: node.id,
          message: 'classify node "${node.id}" has a non-string stage '
              'attribute (${raw.runtimeType}); the node id is used instead',
        ),
      );
    }
    final stage = ClassifyHandler.stageOf(node);
    if (!stages.contains(stage)) {
      diags.add(
        Diagnostic(
          rule: 'classify_stage_known',
          severity: Severity.error,
          nodeId: node.id,
          message: 'classify node "${node.id}" names unknown stage '
              '"$stage" (known: ${stages.join(', ')})',
        ),
      );
    }
  }
  return diags;
}

/// Parse DOT source into a program and run the full validation pass. A parse
/// failure becomes a `dot_parse` error diagnostic rather than a throw, so a
/// broken file on disk surfaces as an invalid program the caller can report.
ClassifyProgram parseClassifyProgram(
  String name,
  String source, {
  required String origin,
  Set<String> stages = kClassifyProgramStages,
}) {
  final Graph graph;
  try {
    graph = parseDot(source);
  } catch (e) {
    return ClassifyProgram(
      name: name,
      origin: origin,
      graph: Graph(name: name),
      diagnostics: [
        Diagnostic(
          rule: 'dot_parse',
          severity: Severity.error,
          message: 'cannot parse program "$name": $e',
        ),
      ],
    );
  }
  return ClassifyProgram(
    name: name,
    origin: origin,
    graph: graph,
    diagnostics: [...validate(graph), ...validateClassifyProgram(graph, stages)],
  );
}

/// The built-in fallback program — what `/index` runs when the workspace has
/// no program of its own, preserving today's sequencing:
///
/// * `start → language → details → exit` (unconditional default: details runs
///   after any non-failed language stage, exactly as `classifyProject` runs
///   framework/tooling regardless of which languages were found);
/// * no failure edge: a `fail` stage takes no unconditional edge (engine
///   edge-selection rule), so a hard language failure ends the run as failed
///   with `details` skipped — `classifyProject`'s old catch-all. An explicit
///   `language → exit [condition="outcome=fail"]` edge would instead *recover*
///   into an exit-success run (attractor `engine_test.dart`, "failed node can
///   take explicit recovery edge"), masking the failure; recovery stays opt-in
///   per program (proposal decisions 6/7).
///
/// No human gate: `/index` must never block on a prompt by default. User
/// programs may add gates freely.
ClassifyProgram builtinIndexProgram({
  Set<String> stages = kClassifyProgramStages,
}) {
  final graph = Graph(
    name: 'index',
    attrs: {'goal': 'Classify the workspace index'},
    nodes: {
      'start': PipelineNode(id: 'start', attrs: {'shape': 'Mdiamond'}),
      'language': PipelineNode(id: 'language', attrs: {'type': 'classify'}),
      'details': PipelineNode(id: 'details', attrs: {'type': 'classify'}),
      'exit': PipelineNode(id: 'exit', attrs: {'shape': 'Msquare'}),
    },
    edges: [
      PipelineEdge(from: 'start', to: 'language'),
      PipelineEdge(from: 'language', to: 'details'),
      PipelineEdge(from: 'details', to: 'exit'),
    ],
  );
  return ClassifyProgram(
    name: 'index',
    origin: 'builtin',
    graph: graph,
    diagnostics: [...validate(graph), ...validateClassifyProgram(graph, stages)],
  );
}

/// Load the program for one `/index` invocation. Precedence (decision 3):
///
/// 1. `<workspaceRoot>/.tina/programs/index.dot` — explicit name wins;
/// 2. the *single* `*.dot` in that directory — an unambiguous one-program
///    workspace is that program;
/// 3. `<globalWorkflowsDir>/index.dot` — a global default;
/// 4. the built-in program — `/index` never regresses to "no program".
///
/// A found file is returned even when invalid ([ClassifyProgram.valid] false)
/// so the caller can surface its diagnostics instead of masking them.
Future<ClassifyProgram> loadIndexProgram({
  required String workspaceRoot,
  Directory? globalWorkflowsDir,
  Set<String> stages = kClassifyProgramStages,
}) async {
  final file = _pickProgramFile(Directory(p.join(workspaceRoot, '.tina', 'programs')));
  final global = file ??
      (globalWorkflowsDir == null
          ? null
          : _existingFile(p.join(globalWorkflowsDir.path, 'index.dot')));
  if (file == null && global == null) {
    return builtinIndexProgram(stages: stages);
  }
  final picked = file ?? global!;
  return parseClassifyProgram(
    p.basenameWithoutExtension(picked.path),
    await picked.readAsString(),
    origin: picked.path,
    stages: stages,
  );
}

/// `index.dot` when present, else the directory's only `*.dot`, else null
/// (zero programs, or several without an index — ambiguous, so fall through).
File? _pickProgramFile(Directory dir) {
  final named = _existingFile(p.join(dir.path, 'index.dot'));
  if (named != null) return named;
  if (!dir.existsSync()) return null;
  final programs =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => p.extension(f.path) == '.dot')
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return programs.length == 1 ? programs.single : null;
}

File? _existingFile(String path) {
  final file = File(path);
  return file.existsSync() ? file : null;
}

/// The built-in index program as editable DOT — what `/classifier-review`
/// offers for adoption. Leading `//` lines are instructions for the reader
/// (the DOT parser accepts comments, and `graphToDot`'s contract keeps
/// `parseDot(graphToDot(g))` structurally identical, so the fragment
/// round-trips through the workflow editor's load → edit → save cycle).
String builtinIndexProgramDot({String focus = ''}) {
  final b = StringBuffer()
    ..writeln('// Classifier program for /index — adopt by saving as')
    ..writeln('//   <workspace>/.tina/programs/index.dot')
    ..writeln('// (or ~/.tina/workflows/index.dot for a global default),')
    ..writeln('// then edit visually: /workflow edit index');
  final narrowed = focus.trim();
  if (narrowed.isNotEmpty) {
    b.writeln('// Review focus: $narrowed');
  }
  b.write(graphToDot(builtinIndexProgram().graph));
  return b.toString();
}

/// The file `/workflow edit <name>` opens: the workspace program
/// `<workspaceRoot>/.tina/programs/<name>.dot` when present (decision 3
/// precedence — classifier programs live with the workspace), else the
/// global `<globalWorkflowsDir>/<name>.dot`, else null. The editor saves
/// back to the opened file's directory.
File? resolveWorkflowProgramFile({
  required String name,
  required String workspaceRoot,
  Directory? globalWorkflowsDir,
}) {
  final local = _existingFile(
    p.join(workspaceRoot, '.tina', 'programs', '$name.dot'),
  );
  if (local != null) return local;
  final global = globalWorkflowsDir;
  return global == null
      ? null
      : _existingFile(p.join(global.path, '$name.dot'));
}
