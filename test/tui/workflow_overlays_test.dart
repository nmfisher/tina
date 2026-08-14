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

  test('node-attr editor: ctrl-s with no edits round-trips context/writes',
      () async {
    final screen = fakeScreen(columns: 80, lines: 24);
    final node = PipelineNode(id: 'plan', attrs: {
      'label': 'Plan',
      'context': 'intake',
      'writes': 'plan',
      'prompt': 'Write the plan.',
    });
    canned.events = [ControlKey(ControlCode.ctrlS)];
    final applied = await runNodeAttrEditor(
      screen: screen,
      editor: LineEditor(screen: screen),
      node: node,
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
    expect(applied, isTrue);
    // The handoff contract survived the serialize -> apply round-trip.
    expect(node.contextKeys, ['intake']);
    expect(node.writesKeys, contains('plan'));
    expect(node.prompt, 'Write the plan.');
    expect(node.label, 'Plan');
  });

  test('node-attr editor: an empty prompt never writes an empty attr key',
      () async {
    final screen = fakeScreen(columns: 80, lines: 24);
    final node = PipelineNode(id: 'plan', attrs: {'label': 'Plan'});
    canned.events = [ControlKey(ControlCode.ctrlS)];
    final applied = await runNodeAttrEditor(
      screen: screen,
      editor: LineEditor(screen: screen),
      node: node,
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
    expect(applied, isTrue);
    expect(node.attrs.containsKey('prompt'), isFalse,
        reason: 'an untouched empty prompt must not add prompt="" noise');
    expect(node.attrs.containsKey('goal_gate'), isFalse);
  });

  test('graph viewer: open then Esc does not crash', () async {
    final screen = fakeScreen(columns: 80, lines: 24);
    final graph = parseDot('''
      digraph V {
        start [shape=Mdiamond]
        done [shape=Msquare]
        a [shape=box, label="A", system_prompt="r"]
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

  test('graph editor: Ctrl-C with unsaved changes asks before discarding',
      () async {
    final screen = fakeScreen(columns: 80, lines: 24);
    final graph = parseDot('''
      digraph E {
        start [shape=Mdiamond]
        done [shape=Msquare]
        a [shape=box, label="A"]
        start -> a -> done
      }
    ''');
    // A wrapper that counts reads: if ctrl-C skipped the discard confirm (the
    // old behavior) the editor would return after ONE event; going through the
    // confirm modal consumes the follow-ups.
    var reads = 0;
    Future<InputEvent> read() {
      reads++;
      return canned.readEvent();
    }

    // ctrl-C -> confirm opens; Esc answers No (keep editing); ctrl-C ->
    // confirm opens again; Enter picks "Yes" -> discard + close.
    canned.events = [
      ControlKey(ControlCode.ctrlC),
      EscapeKey(),
      ControlKey(ControlCode.ctrlC),
      ControlKey(ControlCode.enter),
    ];
    final saved = await runWorkflowEditor(
      screen: screen,
      editor: LineEditor(screen: screen),
      graph: graph,
      name: 'e',
      pipeline: defaultPipeline,
      workflowsDir: Directory.systemTemp, // not written (no save)
      isNew: true, // dirty from the start
      readEvent: read,
    ).timeout(overlayTimeout);
    expect(saved, isFalse);
    // All four events were consumed: both ctrl-Cs opened the confirm (they did
    // not close the editor outright), and the modal read the answers.
    expect(reads, 4);
  });
}
