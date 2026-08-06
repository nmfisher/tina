import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/pipeline/default_workflow.dart';
import 'package:tina/tui/workflow_editor_overlay.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// Regression tests for arrow-key navigation in the visual workflow editor.
/// Beyond "selection changed", each test asserts that the DOUBLE selection
/// box (╔╗╚╝║) visibly moved inside the last painted frame — the editor used
/// to repaint a stale render after arrows, leaving the highlight frozen on
/// the old node while only the footer updated.
void main() {
  final canned = CannedEvents();
  setUp(canned.clear);

  /// The editor overlay's frame start is its title line (`┌ <name> ─...`).
  /// Extract the LAST painted frame so assertions target the final render,
  /// not the accumulated write buffer.
  String lastFrame(String buffer, String title) =>
      buffer.substring(buffer.lastIndexOf('┌ $title '));

  void expectSelectionMoved(String before, String after, String title) {
    final beforeBox = lastFrame(before, title).indexOf('╔');
    final afterBox = lastFrame(after, title).indexOf('╔');
    expect(afterBox, isNot(beforeBox),
        reason: 'selection highlight did not move on screen');
  }

  test('arrows cycle selection via canned events', () async {
    final screen = fakeScreen(columns: 100, lines: 30);
    final graph = parseDot('''
      digraph E {
        start [shape=Mdiamond]
        done [shape=Msquare]
        a [shape=box, label="A"]
        start -> a -> done
      }
    ''');
    canned.events = [
      ArrowKey(ArrowDirection.right),
      ArrowKey(ArrowDirection.right),
      EscapeKey(),
    ];
    final saved = await runWorkflowEditor(
      screen: screen,
      editor: LineEditor(screen: screen),
      graph: graph,
      name: 'e',
      pipeline: defaultPipeline,
      workflowsDir: Directory.systemTemp,
      readEvent: canned.readEvent,
    ).timeout(overlayTimeout);
    expect(saved, isFalse);
  });

  test('arrows cycle selection on the seeded default workflow (back-edge)',
      () async {
    final screen = fakeScreen(columns: 100, lines: 30);
    final graph = parseDot(kDefaultWorkflowDotSource);
    final editor = LineEditor(screen: screen);
    final future = runWorkflowEditor(
      screen: screen,
      editor: editor,
      graph: graph,
      name: 'default',
      pipeline: defaultPipeline,
      workflowsDir: Directory.systemTemp,
    ).timeout(overlayTimeout);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final before = (screen.io as dynamic).written.toString();
    for (var i = 0; i < 4; i++) {
      editor.inject(ArrowKey(ArrowDirection.right));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final after = (screen.io as dynamic).written.toString();
    editor.inject(EscapeKey());
    final saved = await future;
    expect(saved, isFalse);
    expect(after, isNot(before), reason: 'arrow keys did not move the selection');
    expectSelectionMoved(before, after, 'default');
  });

  test('arrows cycle selection via the real editor.readKey path', () async {
    final screen = fakeScreen(columns: 100, lines: 30);
    final graph = parseDot('''
      digraph E {
        start [shape=Mdiamond]
        done [shape=Msquare]
        a [shape=box, label="A"]
        start -> a -> done
      }
    ''');
    final editor = LineEditor(screen: screen);
    final future = runWorkflowEditor(
      screen: screen,
      editor: editor,
      graph: graph,
      name: 'e',
      pipeline: defaultPipeline,
      workflowsDir: Directory.systemTemp,
    ).timeout(overlayTimeout);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final before = (screen.io as dynamic).written.toString();
    editor.inject(ArrowKey(ArrowDirection.right));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final after = (screen.io as dynamic).written.toString();
    editor.inject(EscapeKey());
    final saved = await future;
    expect(saved, isFalse);
    expect(after, isNot(before), reason: 'arrow key did not move the selection');
    expectSelectionMoved(before, after, 'e');
  });

  test('arrows cycle selection from raw terminal bytes (ESC [ C)', () async {
    final screen = fakeScreen(columns: 100, lines: 30);
    final graph = parseDot('''
      digraph E {
        start [shape=Mdiamond]
        done [shape=Msquare]
        a [shape=box, label="A"]
        start -> a -> done
      }
    ''');
    final editor = LineEditor(screen: screen);
    final future = runWorkflowEditor(
      screen: screen,
      editor: editor,
      graph: graph,
      name: 'e',
      pipeline: defaultPipeline,
      workflowsDir: Directory.systemTemp,
    ).timeout(overlayTimeout);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final before = (screen.io as dynamic).written.toString();
    // ESC [ C — the exact bytes a terminal sends for the right arrow.
    (screen.io as dynamic).feedBytes([0x1b, 0x5b, 0x43]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final after = (screen.io as dynamic).written.toString();
    editor.inject(EscapeKey());
    final saved = await future;
    expect(saved, isFalse);
    expect(after, isNot(before),
        reason: 'raw arrow bytes did not move the selection');
    expectSelectionMoved(before, after, 'e');
  });
}
