import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:tina/session_controller.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';

import 'workflow_editor_overlay.dart';
import 'workflow_viewer_overlay.dart';

/// What the `/workflow` viewer and editor overlays need. Explicit deps
/// instead of the coordinator closure's implicit captures.
class WorkflowOverlayDeps {
  final Screen screen;
  final LineEditor editor;
  final Directory workflowsDir;

  /// The repo root whose `.tina/programs/` is searched first by the editor
  /// (workspace programs beat global workflows — decision 3 precedence).
  final String workspaceRoot;

  /// The pipeline used by the editor's node runner.
  final AgentPipeline pipeline;

  /// The active conversation host, resolved at dispatch time so a session
  /// switch cannot leave errors attached to the previous conversation.
  final HostInterface Function() host;

  /// Testable dispatch seams; production uses the real terminal overlays.
  final Future<void> Function({
    required Screen screen,
    required LineEditor editor,
    required Graph graph,
    String? title,
  })?
  viewer;
  final Future<bool> Function({
    required Screen screen,
    required LineEditor editor,
    required Graph graph,
    required String? name,
    required AgentPipeline pipeline,
    required Directory workflowsDir,
    bool isNew,
    Directory? originDir,
  })?
  editorRunner;

  const WorkflowOverlayDeps({
    required this.screen,
    required this.editor,
    required this.workflowsDir,
    required this.workspaceRoot,
    required this.pipeline,
    required this.host,
    this.viewer,
    this.editorRunner,
  });
}

/// Wire the two `/workflow` graph overlays on a [SessionController].
void wireWorkflowOverlayHandlers(
  SessionController controller,
  WorkflowOverlayDeps deps,
) {
  controller.openWorkflowViewer = (name) => openWorkflowViewer(deps, name);
  controller.openWorkflowEditor = ({name, isNew = false}) =>
      openWorkflowEditor(deps, name: name, isNew: isNew);
}

/// `/workflow show` — read a workflow DOT, parse it, run the visual viewer.
/// A missing/unreadable file or a parse error is reported through the host
/// rather than thrown: a bad file must not take the REPL down.
Future<void> openWorkflowViewer(WorkflowOverlayDeps deps, String name) async {
  try {
    final source = await PipelineRunner.readWorkflow(deps.workflowsDir, name);
    final graph = parseDot(source);
    final viewer = deps.viewer;
    if (viewer != null) {
      await viewer(
        screen: deps.screen,
        editor: deps.editor,
        graph: graph,
        title: name,
      );
    } else {
      await runWorkflowViewer(
        screen: deps.screen,
        editor: deps.editor,
        graph: graph,
        title: name,
      );
    }
  } catch (e) {
    deps.host().showMessage('$e\n', style: HostMessageStyle.error);
  }
}

/// `/workflow new` + `/workflow edit` — the visual node editor.
///
/// A new workflow seeds a minimal runnable skeleton (start → exit). An edit
/// opens the workspace program when one exists (and saves back to its origin)
/// or the global workflows dir otherwise; a read/parse failure is reported
/// through the host and the editor does not open.
Future<void> openWorkflowEditor(
  WorkflowOverlayDeps deps, {
  String? name,
  bool isNew = false,
}) async {
  Graph graph;
  Directory? originDir;
  if (isNew) {
    // Seed a minimal runnable skeleton: start → exit, ready to insert into.
    graph = Graph(
      name: 'workflow',
      nodes: {
        'start': PipelineNode(
          id: 'start',
          attrs: {'shape': 'Mdiamond', 'label': 'Start'},
        ),
        'exit': PipelineNode(
          id: 'exit',
          attrs: {'shape': 'Msquare', 'label': 'Done'},
        ),
      },
      edges: [PipelineEdge(from: 'start', to: 'exit')],
    );
  } else {
    final n = name;
    if (n == null) return;
    try {
      // Workspace programs (`<repo>/.tina/programs/<name>.dot`) open
      // first — decision 3 precedence — and save back to their origin;
      // otherwise the global workflows dir decides.
      final file = resolveWorkflowProgramFile(
        name: n,
        workspaceRoot: deps.workspaceRoot,
        globalWorkflowsDir: deps.workflowsDir,
      );
      if (file != null) {
        graph = parseDot(await file.readAsString());
        originDir = file.parent;
      } else {
        graph = parseDot(
          await PipelineRunner.readWorkflow(deps.workflowsDir, n),
        );
      }
    } catch (e) {
      deps.host().showMessage('$e\n', style: HostMessageStyle.error);
      return;
    }
  }
  final editorRunner = deps.editorRunner;
  if (editorRunner != null) {
    await editorRunner(
      screen: deps.screen,
      editor: deps.editor,
      graph: graph,
      name: name,
      pipeline: deps.pipeline,
      workflowsDir: deps.workflowsDir,
      originDir: originDir,
      isNew: isNew,
    );
  } else {
    await runWorkflowEditor(
      screen: deps.screen,
      editor: deps.editor,
      graph: graph,
      name: name,
      pipeline: deps.pipeline,
      workflowsDir: deps.workflowsDir,
      originDir: originDir,
      isNew: isNew,
    );
  }
}
