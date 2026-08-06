import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tui/workflow_editor_overlay.dart';
import 'package:tina/tui/workflow_node_attr_form.dart';
import 'package:tina/tui/workflow_viewer_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// Smoke tests for the workflow overlays: they drive each overlay's `paint()`
/// path with canned input against a Screen over FakeStdio. The point is to
/// catch string-slicing/crash bugs in the render code (a bare open+Esc
/// exercises the full frame build) that pure-Dart renderer tests can't reach.
void main() {
  final canned = CannedEvents();

  setUp(canned.clear);

  test('node-attr editor: open then Esc does not crash paint()', () async {
    final screen = fakeScreen(columns: 80, lines: 24);
    final node = PipelineNode(id: 'plan', attrs: {'role': 'orchestrator'});
    canned.events = [EscapeKey()];
    final applied = await runNodeAttrEditor(
      screen: screen,
      editor: LineEditor(screen: screen),
      node: node,
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
    expect(applied, isFalse);
  });

  test('node-attr editor: Ctrl-S applies edits to the node', () async {
    final screen = fakeScreen(columns: 80, lines: 24);
    final node = PipelineNode(id: 'plan', attrs: {'role': 'orchestrator'});
    // The buffer opens with serialized fields; navigate to the role line and
    // change it. Simplest: the role line is line 1; just save as-is, then
    // separately verify a typed change applies. Here we type into the prompt
    // tail (cursor starts at end) and save.
    canned.events = [
      CharInput(' X'),
      ControlKey(ControlCode.ctrlS),
    ];
    final applied = await runNodeAttrEditor(
      screen: screen,
      editor: LineEditor(screen: screen),
      node: node,
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
    expect(applied, isTrue);
    // The typed text landed in the prompt (everything after `prompt =`).
    expect(node.prompt, contains('X'));
  });

  test('graph viewer: open then Esc does not crash', () async {
    final screen = fakeScreen(columns: 80, lines: 24);
    final graph = parseDot('''
      digraph V {
        start [shape=Mdiamond]
        done [shape=Msquare]
        a [shape=box, label="A", role="r"]
        start -> a -> done
      }
    ''');
    canned.events = [EscapeKey()];
    await runWorkflowViewer(
      screen: screen,
      editor: LineEditor(screen: screen),
      graph: graph,
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
  });

  test('graph editor: open an existing graph then Esc (no changes) closes', () async {
    final screen = fakeScreen(columns: 80, lines: 24);
    final graph = parseDot('''
      digraph E {
        start [shape=Mdiamond]
        done [shape=Msquare]
        a [shape=box, label="A"]
        start -> a -> done
      }
    ''');
    // dirty is false for a non-new edit, so Esc closes without a confirm prompt.
    canned.events = [EscapeKey()];
    final saved = await runWorkflowEditor(
      screen: screen,
      editor: LineEditor(screen: screen),
      graph: graph,
      name: 'e',
      pipeline: defaultPipeline,
      workflowsDir: Directory.systemTemp, // not written (no save)
      isNew: false,
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
    expect(saved, isFalse);
  });
}
