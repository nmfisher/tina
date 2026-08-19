import 'package:tina_console/tina_console.dart';

import 'spawn_overlay.dart';

/// Renders a panel's transcript as a maximized popup: a bordered box at 2/3
/// of the screen, centered, floating over a dimmed (scrimmed) background.
/// Ctrl+O on a highlighted/focused panel opens it (the editor's
/// `onMaximizeToggle` hook); Ctrl+O, Esc, or Ctrl+C closes it.
///
/// The content is a read-only snapshot of the panel's chat buffer
/// ([ScrollingTextRegion.snapshotLines] — scrollback history included), so a
/// small side panel's full transcript is browsable here even though it never
/// fit in its frame. Arrows/PgUp/PgDn pan; the popup owns its own viewport
/// (starting pinned to the newest line), like the tool-output viewer.
Future<void> runMaximizedPanelOverlay({
  required Screen screen,
  required LineEditor editor,
  required String title,
  required ScrollingTextRegion chat,
  Future<InputEvent> Function()? readEvent,
  void Function()? onClosed,
}) async {
  final layout = screen.layout;
  final w = (layout.width * 2 ~/ 3).clamp(20, layout.width);
  final h = (layout.height * 2 ~/ 3).clamp(6, layout.height);
  final rect = Rect(
    row: (layout.height - h) ~/ 2,
    col: (layout.width - w) ~/ 2,
    width: w,
    height: h,
  );

  // The scrim: a full-screen overlay of dim-styled spaces, shown BEFORE the
  // popup so the popup's surface stacks above it.
  final scrim = OverlayRegion(
    screen,
    Rect(row: 0, col: 0, width: layout.width, height: layout.height),
  );
  final popup = OverlayRegion(screen, rect);

  String paint(String s) => screen.colorize('cyan', s);

  final contentRows = h - 4; // title bar + footer + box borders
  var panRow = 1 << 30; // pinned to the newest line on first render

  void paintFrame() {
    final lines = chat.snapshotLines();
    final maxPan = (lines.length - contentRows).clamp(0, 1 << 30);
    if (panRow > maxPan) panRow = maxPan;
    final body = <String>[];
    for (var r = 0; r < contentRows; r++) {
      final idx = panRow + r;
      body.add(idx >= 0 && idx < lines.length ? lines[idx] : '');
    }
    final footer = lines.isEmpty
        ? '(empty)'
        : '↑↓/PgUp-PgDn scroll · ctrl+o or esc close  '
            '[row ${(panRow + 1).clamp(1, lines.length)}/${lines.length}]';
    popup.show(boxLines(
      width: w,
      height: h,
      title: title,
      body: body,
      footer: footer,
      paint: paint,
    ));
  }

  scrim.show([
    for (var r = 0; r < layout.height; r++)
      screen.colorize('2', ' ' * layout.width),
  ]);

  final prev = modalTakeFocus(editor);
  try {
    paintFrame();
    while (true) {
      final ev = await (readEvent ?? editor.readKey)();
      if (ev is EscapeKey ||
          (ev is ControlKey &&
              (ev.code == ControlCode.ctrlC || ev.code == ControlCode.ctrlO))) {
        break;
      }
      if (ev is ArrowKey) {
        switch (ev.direction) {
          case ArrowDirection.up:
            panRow -= 1;
          case ArrowDirection.down:
            panRow += 1;
          case ArrowDirection.pageUp:
            panRow -= contentRows;
          case ArrowDirection.pageDown:
            panRow += contentRows;
          case ArrowDirection.left:
          case ArrowDirection.right:
            break;
        }
        if (panRow < 0) panRow = 0;
        paintFrame();
      }
    }
  } finally {
    popup.hide();
    popup.dispose();
    scrim.hide();
    scrim.dispose();
    // On backends with real z-order (notcurses) destroying the planes reveals
    // the panels beneath; on emulated surfaces (ANSI) hiding erases the whole
    // scrimmed area, so the caller repaints every panel underneath.
    onClosed?.call();
    modalRestoreFocus(editor, prev);
  }
}
