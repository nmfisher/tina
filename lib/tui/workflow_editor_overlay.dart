import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';

import 'spawn_overlay.dart';
import 'workflow_node_attr_form.dart';

import '../pipeline/workflow_names.dart';

/// The visual node editor (`/workflow new` and `/workflow edit <name>`). A
/// full-screen, live-rendered graph with a keyboard-driven selection cursor:
/// arrows move between nodes, and keys add/edit/connect/delete nodes + edges,
/// re-laying-out and re-rendering after every change. Save serializes via
/// [graphToDot] to `~/.tina/workflows/<name>.dot` after [validate].
///
/// Returns true if the workflow was saved.
Future<bool> runWorkflowEditor({
  required Screen screen,
  required LineEditor editor,
  required Graph graph,
  required String? name,
  required AgentPipeline pipeline,
  required Directory workflowsDir,
  bool isNew = false,
  Future<InputEvent> Function()? readEvent,
}) {
  return _WorkflowEditor(
    screen: screen,
    editor: editor,
    graph: graph,
    name: name,
    pipeline: pipeline,
    workflowsDir: workflowsDir,
    isNew: isNew,
    readEvent: readEvent,
  ).run();
}

const _help1 = 'workflow editor — keys:';
const _help2 = '  ↑↓←→ / Tab   move selection (or pan at the edge)';
const _help3 = '  e / Enter    edit the selected node (label, prompt, context, writes, …)';
const _help4 = '  n            new node';
const _help5 = '  c            connect selected → another node';
const _help6 = '  d            delete the selected node';
const _help7 = '  r            re-layout';
const _help8 = '  s            save    |  ?  help    |  esc / ctrl-c  close';

class _WorkflowEditor {
  final Screen screen;
  final LineEditor editor;
  Graph graph;
  final AgentPipeline pipeline;
  final Directory workflowsDir;
  final bool isNew;
  final Future<InputEvent> Function()? readEvent;

  /// The name the graph was loaded under (null for a new graph) — saving in
  /// place is not an overwrite.
  final String? originalName;

  String? currentName;
  bool dirty;
  String? selectedId;
  late NodeLayout layout;
  late OverlayRegion overlay;
  late int w, h, contentRows;
  int panRow = 0, panCol = 0;
  late RenderResult last;
  Focusable? prev;

  _WorkflowEditor({
    required this.screen,
    required this.editor,
    required this.graph,
    required String? name,
    required this.pipeline,
    required this.workflowsDir,
    required this.isNew,
    this.readEvent,
  })  : currentName = name,
        originalName = name,
        dirty = isNew;

  Future<bool> run() async {
    selectedId = graph.findStartNode()?.id ??
        (graph.nodes.keys.isNotEmpty ? graph.nodes.keys.first : null);
    layout = computeLayout(graph);
    final lr = screen.layout;
    w = lr.width;
    h = lr.height;
    contentRows = h - 2;
    overlay = OverlayRegion(screen, Rect(row: 0, col: 0, width: w, height: h));
    last = _render();

    prev = modalTakeFocus(editor);
    try {
      autoPan();
      paint();
      while (true) {
        final ev = await (readEvent ?? editor.readKey)();
        if (ev is EscapeKey ||
            (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
          // Both exits run the same dirty-discard confirm — ctrl-c skipping
          // it silently lost changes.
          if (dirty) {
            final discard = await _confirm('Discard unsaved changes?');
            if (!discard) {
              paint();
              continue;
            }
          }
          return false;
        }
        if (ev is ArrowKey) {
          moveSelection(ev.direction);
          // Re-render: `last` carries the selection border, so a stale render
          // would leave the highlight on the previously selected node.
          last = _render();
          paint();
          continue;
        }
        if (ev is ControlKey && ev.code == ControlCode.enter) {
          await _editNode();
          paint();
          continue;
        }
        if (ev is CharInput) {
          switch (ev.text.toLowerCase()) {
            case 'e':
              await _editNode();
            case 'n':
              await _newNode();
            case 'c':
              await _connect();
            case 'd':
              await _deleteNode();
            case 'r':
              refresh();
            case 's':
              await _save();
            case '?':
              await _help();
            default:
              continue;
          }
          paint();
        } else if (ev is ControlKey && ev.code == ControlCode.tab) {
          _cycleSelection();
          last = _render();
          paint();
        }
      }
    } finally {
      overlay.hide();
      overlay.dispose();
      modalRestoreFocus(editor, prev);
    }
  }

  RenderResult _render() =>
      renderGraph(graph, layout: layout, selectedId: selectedId);

  void refresh() {
    layout = computeLayout(graph);
    last = _render();
    autoPan();
  }

  void autoPan() {
    final c = selectedId == null ? null : last.centers[selectedId];
    if (c != null) {
      if (c.row < panRow) panRow = c.row;
      if (c.row >= panRow + contentRows) panRow = c.row - contentRows + 1;
      if (c.col < panCol) panCol = c.col;
      if (c.col >= panCol + w) panCol = c.col - w + 1;
    }
    panRow = panRow.clamp(0, (last.lines.length - contentRows).clamp(0, 1 << 30));
    panCol = panCol.clamp(0, (_longest(last.lines) - w).clamp(0, 1 << 30));
  }

  void paint() {
    final label = isNew && currentName == null
        ? 'new workflow'
        : (currentName ?? 'workflow');
    final titleSeg = ' $label${dirty ? " *" : ""} ';
    final tFit = titleSeg.length > w - 2 ? titleSeg.substring(0, w - 2) : titleSeg;
    final lines = <String>[
      '┌$tFit${'─' * (w - 2 - tFit.length)}┐',
      for (var r = 0; r < contentRows; r++)
        _cropLine(last.lines, panRow + r, panCol, w),
      _footer(w, selectedId, graph),
    ];
    overlay.show(lines);
  }

  void moveSelection(ArrowDirection dir) {
    if (dir == ArrowDirection.pageUp || dir == ArrowDirection.pageDown) {
      panRow += dir == ArrowDirection.pageUp ? -contentRows : contentRows;
      panRow = panRow.clamp(0, (last.lines.length - contentRows).clamp(0, 1 << 30));
      return;
    }
    final cur = selectedId == null ? null : last.centers[selectedId];
    if (cur == null) return;
    String? best;
    var bestD = 1 << 30;
    last.centers.forEach((id, c) {
      if (id == selectedId) return;
      final inDir = switch (dir) {
        ArrowDirection.left => c.col < cur.col,
        ArrowDirection.right => c.col > cur.col,
        ArrowDirection.up => c.row < cur.row,
        ArrowDirection.down => c.row > cur.row,
        _ => false,
      };
      if (!inDir) return;
      final dr = (c.row - cur.row).abs();
      final dc = (c.col - cur.col).abs();
      final d = (dir == ArrowDirection.left || dir == ArrowDirection.right)
          ? dc + dr * 3
          : dr + dc * 3;
      if (d < bestD) {
        bestD = d;
        best = id;
      }
    });
    if (best != null) {
      selectedId = best;
      autoPan();
    } else {
      // No node that way — pan instead.
      panCol += (dir == ArrowDirection.left)
          ? -4
          : (dir == ArrowDirection.right)
              ? 4
              : 0;
      panRow += (dir == ArrowDirection.up)
          ? -1
          : (dir == ArrowDirection.down)
              ? 1
              : 0;
      autoPan();
    }
  }

  void _cycleSelection() {
    final ids = graph.nodes.keys.toList();
    if (ids.isEmpty) return;
    final i = ids.indexOf(selectedId ?? '');
    selectedId = ids[(i + 1) % ids.length];
    autoPan();
  }

  // -- Mutations -------------------------------------------------------------

  Future<void> _editNode() async {
    final n = selectedId == null ? null : graph.node(selectedId!);
    if (n == null) return;
    final changed = await runNodeAttrEditor(
      screen: screen,
      editor: editor,
      node: n,
      readEvent: readEvent,
    );
    if (changed) dirty = true;
    refresh();
  }

  Future<void> _newNode() async {
    final id = await _lineInput('new node id:');
    if (id == null || id.isEmpty) return;
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    if (graph.nodes.containsKey(safe)) {
      await _inform('A node named "$safe" already exists.');
      return;
    }
    graph.nodes[safe] = PipelineNode(id: safe, attrs: {'shape': 'box', 'label': safe});
    selectedId = safe;
    dirty = true;
    refresh();
  }

  Future<void> _connect() async {
    if (selectedId == null) return;
    final entries = graph.nodes.values
        .where((n) => n.id != selectedId)
        .map((n) => (display: '${n.id}  ${n.label}', value: n.id))
        .toList();
    if (entries.isEmpty) return;
    final target = await runListOverlay<String>(
      screen: screen,
      editor: editor,
      entries: entries,
      title: 'connect ${graph.node(selectedId!)!.label} → ?',
      footer: '↑↓ move · enter select · esc cancel',
      accent: 'cyan',
      readEvent: readEvent,
    );
    if (target == null) return;
    final label = await _lineInput('edge label (blank ok):') ?? '';
    graph.edges.add(PipelineEdge(from: selectedId!, to: target, label: label));
    dirty = true;
    refresh();
  }

  Future<void> _deleteNode() async {
    if (selectedId == null) return;
    final n = graph.node(selectedId!)!;
    final hasEdges =
        graph.edges.any((e) => e.from == n.id || e.to == n.id);
    if (hasEdges) {
      final ok = await _confirm('Delete "$selectedId" and its edges?');
      if (!ok) return;
    }
    graph.edges.removeWhere((e) => e.from == n.id || e.to == n.id);
    graph.nodes.remove(n.id);
    selectedId = graph.nodes.keys.firstOrNull;
    dirty = true;
    refresh();
  }

  Future<void> _save() async {
    if (currentName == null || currentName!.isEmpty) {
      final named = await _lineInput('save as (workflow name):');
      if (named == null || named.isEmpty) return;
      final safe = normalizeWorkflowName(named);
      if (safe == null) {
        await _inform('Cannot save — $nameRejection.');
        return;
      }
      currentName = safe;
    }
    final diags = validate(graph);
    final errors = diags.where((d) => d.severity == Severity.error).toList();
    if (errors.isNotEmpty) {
      await _inform('Cannot save — ${errors.length} error(s):\n'
          '${errors.take(5).map((d) => '  $d').join('\n')}');
      return;
    }
    if (!workflowsDir.existsSync()) workflowsDir.createSync(recursive: true);
    final file = File(p.join(workflowsDir.path, '$currentName.dot'));
    // Saving under a name that already holds a DIFFERENT workflow (rename,
    // or a new workflow colliding) must not silently clobber it.
    if (file.existsSync() && file.path != _loadedPath) {
      final overwrite =
          await _confirm('"$currentName" already exists — overwrite it?');
      if (!overwrite) return;
    }
    await file.writeAsString(graphToDot(graph));
    dirty = false;
    await _inform('Saved → ${file.path}');
  }

  /// The file this graph was loaded from (null for a brand-new graph) —
  /// saving in place is not an overwrite.
  String? get _loadedPath => originalName == null
      ? null
      : p.join(workflowsDir.path, '$originalName.dot');

  Future<void> _help() async => _inform(
        [_help1, _help2, _help3, _help4, _help5, _help6, _help7, _help8].join('\n'));

  // -- Small input overlays --------------------------------------------------

  Future<String?> _lineInput(String prompt) async =>
      _LineInput(screen: screen, editor: editor, prompt: prompt, readEvent: readEvent)
          .run();

  Future<bool> _confirm(String prompt) async {
    final entries = [
      (display: 'Yes', value: true),
      (display: 'No', value: false),
    ];
    final v = await runListOverlay<bool>(
      screen: screen,
      editor: editor,
      entries: entries,
      title: prompt,
      footer: 'enter select · esc = No',
      readEvent: readEvent,
    );
    return v ?? false;
  }

  Future<void> _inform(String message) async {
    final lines = message.split('\n');
    await runListOverlay<String>(
      screen: screen,
      editor: editor,
      entries: [
        for (final l in lines) (display: l, value: l),
        (display: '', value: ''),
        (display: '[ok]', value: 'ok'),
      ],
      title: 'workflow',
      footer: 'enter to dismiss',
      readEvent: readEvent,
    );
  }
}

/// A tiny single-line text input overlay (we can't use `editor.readLine` while
/// a full-screen overlay owns the screen). Enter/ctrl-s commits; esc cancels.
class _LineInput {
  final Screen screen;
  final LineEditor editor;
  final String prompt;
  final Future<InputEvent> Function()? readEvent;
  _LineInput({
    required this.screen,
    required this.editor,
    required this.prompt,
    this.readEvent,
  });

  Future<String?> run() async {
    var val = '';
    final lr = screen.layout;
    final w = (lr.width - 8).clamp(40, 80);
    final overlay =
        OverlayRegion(screen, Rect(row: lr.height ~/ 2, col: (lr.width - w) ~/ 2, width: w, height: 3));

    List<String> frame() {
      final inner = w - 4;
      final shown = val.length > inner ? val.substring(val.length - inner) : val;
      final title = prompt.length > w - 4 ? prompt.substring(0, w - 4) : prompt;
      return [
        '┌ $title ${'─' * (w - 4 - title.length - 1)}┐',
        '│ $shown${' ' * (inner - shown.length)} │',
        '└${'─' * (w - 2)}┘',
      ];
    }

    void paint() => overlay.show(frame());

    final prev = modalTakeFocus(editor);
    try {
      paint();
      while (true) {
        final ev = await (readEvent ?? editor.readKey)();
        if (ev is EscapeKey ||
            (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
          return null;
        }
        if (ev is ControlKey &&
            (ev.code == ControlCode.enter || ev.code == ControlCode.ctrlS)) {
          return val;
        }
        if (ev is ControlKey && ev.code == ControlCode.backspace) {
          if (val.isNotEmpty) val = val.substring(0, val.length - 1);
        } else if (ev is CharInput) {
          val += ev.text;
        }
        paint();
      }
    } finally {
      overlay.hide();
      overlay.dispose();
      modalRestoreFocus(editor, prev);
    }
  }
}

// -- shared helpers ----------------------------------------------------------

int _longest(List<String> lines) =>
    lines.fold<int>(0, (m, s) => s.length > m ? s.length : m);

String _cropLine(List<String> lines, int row, int col, int w) {
  if (row < 0 || row >= lines.length) return ' ' * w;
  final src = lines[row];
  String out;
  if (col >= src.length) {
    out = '';
  } else if (col < 0) {
    out = ' ' * (-col).clamp(0, w) + src.substring(0, src.length.clamp(0, w + col));
  } else {
    out = src.substring(col);
  }
  return out.length >= w ? out.substring(0, w) : out.padRight(w);
}

String _footer(int w, String? selectedId, Graph graph) {
  final left = ' e edit · n new · c connect · d delete · r relayout · s save · ? help · esc close ';
  final sel = selectedId == null ? '' : '  [${graph.node(selectedId)?.label ?? selectedId}]';
  final s = '$left$sel';
  final inner = w - 2;
  final fit = s.length > inner ? s.substring(0, inner) : s;
  return '└$fit${' ' * (inner - fit.length)}┘';
}
