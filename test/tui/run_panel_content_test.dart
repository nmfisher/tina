import 'dart:async';

import 'package:attractor/attractor.dart';
import 'package:tina/pipeline/workflow_supervisor.dart';
import 'package:tina/tui/run_panel_content.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// Pins [RunPanelContent]'s pure line builder: the status line, the pannable
/// graph viewport (status glyphs in box borders), the colored per-node status
/// list in layout order, the legend, and the error state for an unavailable
/// graph. Paints (fit/attach) are exercised for crash-freedom; content
/// assertions go through [RunPanelContent.buildLines], the unit-test seam.
void main() {
  late Screen screen;

  setUp(() {
    final io = FakeStdio()..columns = 120;
    final layout =
        ScreenLayout.fromSize(120, 24, split: true, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
  });

  Graph graph() => parseDot('''
    digraph T {
      start [shape=Mdiamond]
      plan [shape=box, label="Plan"]
      exec [shape=box, label="Exec"]
      done [shape=Msquare]
      start -> plan -> exec -> done
    }
  ''');

  WorkflowRun run({
    WorkflowRunStatus status = WorkflowRunStatus.running,
    Map<String, NodeRunStatus>? nodeStatus,
  }) =>
      WorkflowRun(
        id: '1',
        workflowName: 'default',
        conversationId: 'c1',
        goal: null,
        input: 'task',
        cancel: Completer<void>(),
      )
        ..status = status
        ..nodeStatus.addAll(nodeStatus ?? {});

  test('running state: status line, glyphs, colored list, legend', () {
    final content = RunPanelContent(
      screen: screen,
      graph: graph(),
      run: run(nodeStatus: {
        'plan': NodeRunStatus.running,
        'exec': NodeRunStatus.done,
      }),
    );
    content.updateStatus();
    final lines = content.buildLines(40, 12);
    final canvas = lines.join('\n');

    // Status line: RUNNING + tally, colored.
    expect(lines.first, contains('RUNNING'));
    expect(lines.first, contains('2/4 nodes'));
    expect(lines.first, contains('\x1b['));
    // The graph viewport shows a running node's heavy border.
    expect(canvas, contains('┏'));
    expect(canvas, contains('┛'));
    // Status list in layout order: plan running (cyan ▶), exec done (green ✔),
    // start/done pending (·).
    expect(canvas, contains('▶ plan'));
    expect(canvas, contains('✔ exec'));
    expect(canvas, contains('· start'));
    expect(canvas, contains('· done'));
    // Legend with hints (checked on a wider panel — at 40 cols the legend is
    // truncated and the trailing hint keys drop off).
    final wide = content.buildLines(60, 12);
    expect(wide.last, contains('▶ run'));
    expect(wide.last, contains('s stop'));
    expect(wide.last, contains('x close'));
  });

  test('completed/failed/cancelled status lines', () {
    final done = RunPanelContent(
        screen: screen, graph: graph(), run: run(status: WorkflowRunStatus.completed));
    final failed = RunPanelContent(
        screen: screen, graph: graph(), run: run(status: WorkflowRunStatus.failed));
    final cancelled = RunPanelContent(
        screen: screen,
        graph: graph(),
        run: run(status: WorkflowRunStatus.cancelled));

    expect(done.buildLines(40, 12).first, contains('COMPLETED'));
    expect(failed.buildLines(40, 12).first, contains('FAILED'));
    expect(cancelled.buildLines(40, 12).first, contains('CANCELLED'));
  });

  test('failed + skipped nodes get the right list glyphs and colors', () {
    final content = RunPanelContent(
      screen: screen,
      graph: graph(),
      run: run(nodeStatus: {
        'exec': NodeRunStatus.failed,
        'plan': NodeRunStatus.skipped,
      }),
    );
    content.updateStatus();
    final canvas = content.buildLines(40, 12).join('\n');
    expect(canvas, contains('✖ exec'));
    expect(canvas, contains('↷ plan'));
    // Graph borders: failed = double, skipped = plain.
    expect(canvas, contains('╔'));
  });

  test('pan clamps the viewport (handleKey)', () {
    final content = RunPanelContent(
      screen: screen,
      graph: graph(),
      run: run(),
    );
    content.updateStatus();
    // The viewport lives in a fitted interior (handleKey needs its geometry).
    content.fit(const Rect(row: 3, col: 78, width: 40, height: 12),
        reserveInputRow: false);
    // Panning right/down far beyond the canvas clamps, doesn't throw.
    for (var i = 0; i < 50; i++) {
      expect(content.handleKey(ArrowKey(ArrowDirection.right)), isTrue);
      expect(content.handleKey(ArrowKey(ArrowDirection.down)), isTrue);
    }
    final lines = content.buildLines(40, 12);
    // Every row fits the panel width in display columns (raw length includes
    // the SGR wrappers of colored rows).
    for (final l in lines) {
      expect(_visibleLen(l), lessThanOrEqualTo(40), reason: l);
    }
    // Non-arrow keys are not consumed here (the coordinator handles s/x).
    expect(content.handleKey(CharInput('s')), isFalse);
  });

  test('an unavailable graph renders the error in the legend', () {
    final content = RunPanelContent(
      screen: screen,
      graph: null,
      run: run(),
      error: 'graph unavailable: no such file',
    );
    content.updateStatus();
    final lines = content.buildLines(40, 12);
    expect(lines.last, contains('graph unavailable'));
    expect(lines.join('\n'), contains('RUNNING'));
  });

  test('fit/attach/detach paint without crashing', () {
    final content = RunPanelContent(
      screen: screen,
      graph: graph(),
      run: run(),
    );
    content.updateStatus();
    content.fit(const Rect(row: 3, col: 78, width: 40, height: 18),
        reserveInputRow: false);
    content.attach();
    content.detach();
    content.fit(const Rect(row: 3, col: 78, width: 38, height: 16),
        reserveInputRow: false);
    content.updateStatus();
  });
}

/// Display width of [s], skipping ANSI escape sequences (raw length counts
/// the SGR wrappers of colored rows).
int _visibleLen(String s) {
  var n = 0;
  var i = 0;
  while (i < s.length) {
    if (s[i] == '\x1b' && i + 1 < s.length && s[i + 1] == '[') {
      i += 2;
      while (i < s.length) {
        final c = s.codeUnitAt(i);
        i++;
        if (c >= 0x40 && c <= 0x7e) break;
      }
      continue;
    }
    n++;
    i++;
  }
  return n;
}
