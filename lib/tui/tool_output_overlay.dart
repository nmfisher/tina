import 'package:tina_console/tina_console.dart';

import 'spawn_overlay.dart';

/// A read-only, full-screen text viewer (`/output`) for a tool call's capped
/// streamed output. The full text stays in memory as a [List<String>]; only
/// the visible rows are painted each frame (the [OverlayRegion] drops lines
/// past its bounds), so a multi-thousand-line dump is cheap to host. Arrow
/// keys pan, Esc/Ctrl-C close — the same loop as [runWorkflowViewer].
Future<void> runToolOutputViewer({
  required Screen screen,
  required LineEditor editor,
  required String title,
  required String text,
  Future<InputEvent> Function()? readEvent,
}) async {
  final lines = text.split('\n');

  final layoutRect = screen.layout;
  final w = layoutRect.width;
  final h = layoutRect.height;
  final overlay = OverlayRegion(screen, Rect(row: 0, col: 0, width: w, height: h));

  final contentRows = h - 2; // title + footer
  final maxLine = lines.fold<int>(0, _longer);
  var panRow = 0;
  var panCol = 0;

  String frame() {
    final out = <String>[];
    out.add(_title(title, w));
    for (var r = 0; r < contentRows; r++) {
      final src = panRow + r < 0 || panRow + r >= lines.length
          ? ''
          : lines[panRow + r];
      out.add(_crop(src, panCol, w));
    }
    out.add(_footer(w, panRow, panCol, lines.length, maxLine, contentRows, w));
    return out.join('\n');
  }

  void paint() => overlay.show(frame().split('\n'));

  final prev = modalTakeFocus(editor);
  try {
    paint();
    while (true) {
      final ev = await (readEvent ?? editor.readKey)();
      if (ev is EscapeKey ||
          (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
        break;
      }
      var handled = true;
      if (ev is ArrowKey) {
        switch (ev.direction) {
          case ArrowDirection.up:
            panRow -= 1;
          case ArrowDirection.down:
            panRow += 1;
          case ArrowDirection.left:
            panCol -= 3;
          case ArrowDirection.right:
            panCol += 3;
          case ArrowDirection.pageUp:
            panRow -= contentRows;
          case ArrowDirection.pageDown:
            panRow += contentRows;
        }
      } else {
        handled = false;
      }
      if (handled) {
        panRow = panRow.clamp(0, (lines.length - contentRows).clamp(0, 1 << 30));
        panCol = panCol.clamp(0, (maxLine - w).clamp(0, 1 << 30));
        paint();
      }
    }
  } finally {
    overlay.hide();
    overlay.dispose();
    modalRestoreFocus(editor, prev);
  }
}

int _longer(int m, String s) => s.length > m ? s.length : m;

String _crop(String s, int col, int w) {
  if (col >= s.length) return ' ' * w;
  final out = col < 0
      ? ' ' * (-col).clamp(0, w) + s.substring(0, (s.length).clamp(0, w + col))
      : s.substring(col);
  return (out.length >= w) ? out.substring(0, w) : out.padRight(w);
}

String _title(String t, int w) {
  final inner = w - 4;
  final label = t.length > inner ? t.substring(0, inner) : t;
  final pad = inner - label.length;
  return '┌ $label ${'─' * pad}┐';
}

String _footer(int w, int panRow, int panCol, int total, int maxLine,
    int contentRows, int width) {
  final right = '←→↑↓/PgUp-PgDn pan · esc close'
      '  [row ${panRow + 1}/${total}]';
  final left = '';
  final inner = w - 2;
  final s = '$left$right';
  final fit = s.length > inner ? s.substring(0, inner) : s;
  return '└$fit${' ' * (inner - fit.length)}┘';
}
