import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina/tui/workflow_overlay_handlers.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/overlay_fixtures.dart';

void main() {
  late Directory root;
  late Directory workspace;
  late Directory global;
  late FakeHostInterface host;
  late Screen screen;
  late LineEditor editor;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-workflow-handlers-');
    workspace = Directory(p.join(root.path, 'workspace'))..createSync();
    global = Directory(p.join(root.path, 'global'))..createSync();
    host = FakeHostInterface();
    screen = fakeScreen();
    editor = LineEditor(screen: screen);
    addTearDown(editor.close);
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  });

  WorkflowOverlayDeps deps({
    HostInterface Function()? hostProvider,
    Future<void> Function({
      required Screen screen,
      required LineEditor editor,
      required Graph graph,
      String? title,
    })?
    viewer,
    Future<bool> Function({
      required Screen screen,
      required LineEditor editor,
      required Graph graph,
      required String? name,
      required AgentPipeline pipeline,
      required Directory workflowsDir,
      bool isNew,
      Directory? originDir,
    })?
    editorRunner,
  }) {
    return WorkflowOverlayDeps(
      screen: screen,
      editor: editor,
      workflowsDir: global,
      workspaceRoot: workspace.path,
      pipeline: defaultPipeline,
      host: hostProvider ?? () => host,
      viewer: viewer,
      editorRunner: editorRunner,
    );
  }

  test(
    'viewer reads the global workflow and dispatches its parsed graph',
    () async {
      File(p.join(global.path, 'demo.dot')).writeAsStringSync('''
      digraph demo {
        start [shape=Mdiamond]
        finish [shape=Msquare]
        start -> finish
      }
    ''');
      Graph? opened;
      String? titleValue;
      await openWorkflowViewer(
        deps(
          viewer:
              ({
                required screen,
                required editor,
                required graph,
                String? title,
              }) async {
                opened = graph;
                titleValue = title;
              },
        ),
        'demo',
      );

      expect(opened, isNotNull);
      expect(opened!.nodes.keys, containsAll(['start', 'finish']));
      expect(titleValue, 'demo');
      expect(host.messages, isEmpty);
    },
  );

  test('viewer reports a missing workflow through the active host', () async {
    await openWorkflowViewer(
      deps(
        viewer:
            ({
              required screen,
              required editor,
              required graph,
              String? title,
            }) async {},
      ),
      'missing',
    );

    expect(host.messages, hasLength(1));
    expect(host.messages.single, contains('missing.dot'));
    expect(host.messages.single, endsWith('\n'));
  });

  test('editor prefers a workspace program over the global workflow', () async {
    final workspacePrograms = Directory(
      p.join(workspace.path, '.tina', 'programs'),
    )..createSync(recursive: true);
    final workspaceFile = File(p.join(workspacePrograms.path, 'index.dot'))
      ..writeAsStringSync(
        'digraph workspace { a [shape=box] b [shape=Msquare] a -> b }',
      );
    File(p.join(global.path, 'index.dot')).writeAsStringSync(
      'digraph global { global [shape=box] global_end [shape=Msquare] '
      'global -> global_end }',
    );

    Graph? opened;
    Directory? origin;
    await openWorkflowEditor(
      deps(
        editorRunner:
            ({
              required screen,
              required editor,
              required graph,
              required name,
              required pipeline,
              required workflowsDir,
              bool isNew = false,
              Directory? originDir,
            }) async {
              opened = graph;
              origin = originDir;
              return false;
            },
      ),
      name: 'index',
    );

    expect(opened!.nodes.keys, contains('a'));
    expect(opened!.nodes.keys, isNot(contains('global')));
    expect(origin!.path, workspaceFile.parent.path);
  });

  test('editor falls back to the global workflow and saves there', () async {
    File(p.join(global.path, 'default.dot')).writeAsStringSync(
      'digraph default { start [shape=Mdiamond] done [shape=Msquare] start -> done }',
    );

    Graph? opened;
    Directory? origin;
    await openWorkflowEditor(
      deps(
        editorRunner:
            ({
              required screen,
              required editor,
              required graph,
              required name,
              required pipeline,
              required workflowsDir,
              bool isNew = false,
              Directory? originDir,
            }) async {
              opened = graph;
              origin = originDir;
              return false;
            },
      ),
      name: 'default',
    );

    expect(opened!.nodes.keys, containsAll(['start', 'done']));
    expect(origin!.path, global.path);
  });

  test(
    'new editor seeds a start-to-exit skeleton without reading disk',
    () async {
      var read = false;
      await openWorkflowEditor(
        deps(
          editorRunner:
              ({
                required screen,
                required editor,
                required graph,
                required name,
                required pipeline,
                required workflowsDir,
                bool isNew = false,
                Directory? originDir,
              }) async {
                read = true;
                expect(graph.nodes.keys, containsAll(['start', 'exit']));
                expect(graph.edges.single.from, 'start');
                expect(graph.edges.single.to, 'exit');
                expect(originDir, isNull);
                expect(isNew, isTrue);
                return false;
              },
        ),
        name: 'new',
        isNew: true,
      );
      expect(read, isTrue);
    },
  );

  test('editor without a name is a no-op', () async {
    var called = false;
    await openWorkflowEditor(
      deps(
        editorRunner:
            ({
              required screen,
              required editor,
              required graph,
              required name,
              required pipeline,
              required workflowsDir,
              bool isNew = false,
              Directory? originDir,
            }) async {
              called = true;
              return false;
            },
      ),
    );
    expect(called, isFalse);
  });
}
