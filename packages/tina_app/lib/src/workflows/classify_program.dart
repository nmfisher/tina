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
/// * `language → exit` on `outcome=fail` (an explicit failure route, per the
///   engine's rule that failures only follow explicit outcome conditions).
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
      PipelineEdge(from: 'language', to: 'exit', condition: 'outcome=fail'),
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
