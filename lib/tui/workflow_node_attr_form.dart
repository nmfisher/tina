import 'dart:math' as math;

import 'package:attractor/attractor.dart';
import 'package:tina_console/tina_console.dart';

import 'spawn_overlay.dart';

/// Edit a node's attributes as a single structured text block — one
/// [TextBuffer] for every field, which is far less code than a per-field form
/// and stays true to the DOT ethos. The block shape is:
/// ```
/// label = Chat
/// role = main
/// shape = box
/// goal_gate = false
/// max_retries =
/// model = deepseek/deepseek-chat   (optional "provider/model" override)
/// prompt =
/// <free-form prompt — everything after the `prompt =` line>
/// ```
/// ctrl-s parses and applies; esc cancels. Returns true if applied.
Future<bool> runNodeAttrEditor({
  required Screen screen,
  required LineEditor editor,
  required PipelineNode node,
  Future<InputEvent> Function()? readEvent,
}) async {
  final initial = _serialize(node);
  final buf = TextBuffer(initial: initial);

  final layout = screen.layout;
  final w = (layout.width - 4).clamp(60, layout.width - 2);
  final h = (layout.height - 4).clamp(14, layout.height - 2);
  final rect = Rect(
    row: (layout.height - h) ~/ 2,
    col: (layout.width - w) ~/ 2,
    width: w,
    height: h,
  );
  final overlay = OverlayRegion(screen, rect);
  final innerW = rect.width - 4;
  final editorRows = rect.height - 4;
  var scrollLine = 0;

  List<String> body() {
    final rows = List<String>.filled(editorRows, '', growable: true);
    var first = scrollLine;
    if (buf.line < first) first = buf.line;
    if (buf.line >= first + editorRows) first = buf.line - editorRows + 1;
    first = first.clamp(0, math.max(0, buf.lineCount - 1));
    scrollLine = first;
    for (var r = 0; r < editorRows; r++) {
      final ln = first + r;
      if (ln >= buf.lineCount) {
        rows[r] = '~';
        continue;
      }
      final text = buf.lines[ln];
      if (ln != buf.line) {
        rows[r] = text.length > innerW ? text.substring(0, innerW) : text;
      } else {
        var start = 0;
        if (text.length > innerW) {
          start = (buf.col - innerW + 1).clamp(0, text.length - innerW);
        }
        rows[r] = text.substring(start, math.min(text.length, start + innerW));
      }
    }
    return rows;
  }

  void paint() {
    final title = 'Edit node: ${node.id}';
    final titleSeg = ' $title ';
    final tFit = titleSeg.length > rect.width - 2
        ? titleSeg.substring(0, rect.width - 2)
        : titleSeg;
    const footer = 'ctrl-s save · esc cancel · ↑↓←→ move · enter newline';
    final footerFit = footer.substring(0, math.min(innerW, footer.length));
    final lines = <String>[
      '┌$tFit${'─' * (rect.width - 2 - tFit.length)}┐',
      for (final b in body()) '│ ${b.padRight(innerW).substring(0, innerW)} │',
      '│ ${footerFit.padRight(innerW)} │',
      '└${'─' * (rect.width - 2)}┘',
    ];
    overlay.show(lines);
    // Park the cursor at the edit cell.
    final displayLine = buf.line - scrollLine;
    if (displayLine >= 0 && displayLine < editorRows) {
      final text = buf.currentLine;
      var start = 0;
      if (text.length > innerW) {
        start = (buf.col - innerW + 1).clamp(0, text.length - innerW);
      }
      screen.parkCursorAt(rect.row + 1 + displayLine, rect.col + 2 + (buf.col - start));
    }
  }

  final prev = modalTakeFocus(editor);
  try {
    paint();
    while (true) {
      final ev = await (readEvent ?? editor.readKey)();
      if (ev is EscapeKey || (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
        return false;
      }
      if (ev is ControlKey && ev.code == ControlCode.ctrlS) {
        _apply(node, buf.text);
        return true;
      }
      if (ev is CharInput) {
        buf.insert(ev.text);
      } else if (ev is ControlKey) {
        switch (ev.code) {
          case ControlCode.backspace:
            buf.backspace();
          case ControlCode.enter:
            buf.splitLine();
          case ControlCode.tab:
            buf.insert('  ');
          default:
            break;
        }
      } else if (ev is EditingKey) {
        switch (ev.action) {
          case EditingAction.home:
            buf.moveLineHome();
          case EditingAction.end:
            buf.moveLineEnd();
          case EditingAction.delete:
          case EditingAction.deleteWordForward:
            buf.deleteForward();
          case EditingAction.killToStart:
          case EditingAction.deleteWordBackward:
            buf.backspace();
          case EditingAction.killToEnd:
            break;
        }
      } else if (ev is ArrowKey) {
        switch (ev.direction) {
          case ArrowDirection.up:
            buf.moveUp();
          case ArrowDirection.down:
            buf.moveDown();
          case ArrowDirection.left:
            buf.moveLeft();
          case ArrowDirection.right:
            buf.moveRight();
          case ArrowDirection.pageUp:
          case ArrowDirection.pageDown:
            break;
        }
      }
      paint();
    }
  } finally {
    overlay.hide();
    overlay.dispose();
    modalRestoreFocus(editor, prev);
  }
}

String _serialize(PipelineNode n) {
  final buf = StringBuffer();
  buf.writeln('label = ${n.label == n.id ? '' : n.label}');
  buf.writeln('role = ${n.role}');
  buf.writeln('shape = ${n.shape}');
  buf.writeln('goal_gate = ${n.goalGate}');
  buf.writeln('max_retries = ${n.maxRetries ?? ''}');
  buf.writeln('model = ${n.model}');
  buf.writeln('retry_target = ${n.retryTarget}');
  buf.writeln('prompt =');
  buf.write(n.prompt.isNotEmpty ? n.prompt : '');
  return buf.toString();
}

void _apply(PipelineNode n, String text) {
  final lines = text.split('\n');
  var promptStarted = false;
  final prompt = StringBuffer();
  for (final raw in lines) {
    if (promptStarted) {
      prompt.writeln(raw);
      continue;
    }
    if (raw.trim() == 'prompt =' || raw.trim() == 'prompt=') {
      promptStarted = true;
      continue;
    }
    final eq = raw.indexOf('=');
    if (eq < 0) continue;
    final key = raw.substring(0, eq).trim();
    final value = raw.substring(eq + 1).trim();
    switch (key) {
      case 'label':
        n.attrs['label'] = value.isEmpty ? n.id : value;
      case 'role':
        if (value.isEmpty) {
          n.attrs.remove('role');
        } else {
          n.attrs['role'] = value;
        }
      case 'shape':
        n.attrs['shape'] = value.isEmpty ? 'box' : value;
      case 'goal_gate':
        n.attrs['goal_gate'] = value == 'true';
      case 'max_retries':
        if (value.isEmpty) {
          n.attrs.remove('max_retries');
        } else {
          final parsed = int.tryParse(value);
          if (parsed != null) n.attrs['max_retries'] = parsed;
        }
      case 'model':
        if (value.isEmpty) {
          n.attrs.remove('model');
        } else {
          n.attrs['model'] = value;
        }
      case 'retry_target':
        if (value.isEmpty) {
          n.attrs.remove('retry_target');
        } else {
          n.attrs['retry_target'] = value;
        }
    }
  }
  // Everything after `prompt =` (trim trailing newline added by writeln).
  var p = prompt.toString();
  if (p.endsWith('\n')) p = p.substring(0, p.length - 1);
  n.attrs['prompt'] = p;
}
