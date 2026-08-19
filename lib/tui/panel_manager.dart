import 'package:tina_console/tina_console.dart';

import '../platform/terminal_geometry.dart';
import 'tree_order.dart';
import '../tui_coordinator.dart' show SpawnTree;

/// Content-agnostic panel geometry, focus ring, and shared-input relocation.
///
/// Owns the [primaryFrame] and the right-column [spawnedFrames], lays them out
/// (the tiling math), registers/removes them in the focus ring, and moves the
/// shared input line onto whichever panel is active. It knows nothing about the
/// content those frames hold — content positioning is the
/// [ConversationPanelCoordinator]'s job (Phase 5), so this stays a pure-geometry
/// seam that can be unit-tested against the real [Screen]/[FocusManager].
class PanelManager {
  PanelManager({
    required this.screen,
    required this.focusManager,
    required this.editor,
    required this.primaryFrame,
    required this.terminalGeometry,
    required this.menuBarEnabled,
    required this.tree,
  });

  final Screen screen;
  final FocusManager focusManager;
  final LineEditor editor;
  final PanelFrame primaryFrame;
  final TerminalGeometry terminalGeometry;
  final bool menuBarEnabled;
  final SpawnTree tree;

  final List<PanelFrame> spawnedFrames = [];

  /// Minimum height of a side-column panel, border rows included. When the
  /// stacked panels cannot all fit at this height, the column scrolls: a
  /// window of panels is tiled and the rest park at virtual off-screen slots
  /// (invisible but cyclable) until focus or the cycling highlight scrolls
  /// them into view ([ensureVisible]). Indicator rows above/below the stack
  /// name how many panels are hidden on each side.
  static const int minPanelHeight = 10;

  /// Index (into the tree-ordered panel list) of the first VISIBLE panel while
  /// the column scrolls. Kept in range by [layout]; moved by [ensureVisible].
  /// Irrelevant while every panel fits ([layout] pins it to 0).
  int _scrollOffset = 0;

  /// The panel whose input state is currently loaded in the editor. Tracked here
  /// so [relocateInput] can save/restore per-panel input across focus changes.
  PanelFrame? _inputFrame;

  bool get hasSpawnedFrames => spawnedFrames.isNotEmpty;

  /// The primary frame followed by the spawned frames, in stable list order.
  /// Used to relay content into every frame after a layout pass.
  List<PanelFrame> get allFrames => [primaryFrame, ...spawnedFrames];

  /// Add a spawned frame to the tiling list and register it in the focus ring
  /// (Tab-cyclable); the primary stays active. Content relay into the frame's
  /// interior is the coordinator's job (after every [layout]).
  void addFrame(PanelFrame f) {
    spawnedFrames.add(f);
    focusManager.register(f);
  }

  /// Remove a spawned frame from the ring + list and release its busy timer.
  void removeFrame(PanelFrame f) {
    focusManager.unregister(f);
    spawnedFrames.remove(f);
    f.dispose();
  }

  /// Resize the screen to the current terminal size with the given split/info
  /// frame policy — the first step of every resize. Pure geometry: only touches
  /// [Screen.layout]; the frames laid out against that layout is [layout]'s job.
  void applyScreenLayout({required bool split, required bool drawInfoFrame}) {
    screen.resize(ScreenLayout.fromSize(
      terminalGeometry.columns,
      terminalGeometry.lines,
      hasMenuBar: menuBarEnabled,
      split: split,
      drawInfoFrame: drawInfoFrame,
    ));
  }

  /// Lay out every panel: the primary (left column, or full width) plus the
  /// spawned frames tiled into the right column, indented by tree depth. Pure
  /// geometry — calls [PanelFrame.setOuter] only; the content those frames hold
  /// is positioned separately.
  void layout() {
    final layout = screen.layout;
    // The primary panel owns the chat box (border-inclusive): the full width
    // when not split, or the left column up to the divider when split.
    primaryFrame.setOuter(Rect(
      row: layout.topBorderRow,
      col: layout.chatLeftCol,
      width: layout.chatRightCol - layout.chatLeftCol + 1,
      height: layout.bottomBorderRow - layout.topBorderRow + 1,
    ));

    final info = layout.info;
    if (info.isEmpty) return; // no right column
    // Clear the entire right column — interior AND border perimeter — so the
    // switch from full-width (no split) to split leaves no stale cells from
    // the primary's previously full-width border. Each spawned panel repaints
    // its own border + content below.
    for (var r = 0; r < layout.height; r++) {
      screen.eraseAtAbsolute(
        row: r,
        col: layout.infoLeftCol,
        n: layout.width - layout.infoLeftCol,
        moveCursor: false,
      );
    }
    if (spawnedFrames.isEmpty) return;
    // Panels self-draw their borders, so lay them out over the full info BOX
    // (border rows inclusive: topBorderRow..bottomBorderRow) — not the
    // interior — so each panel's top/bottom border lands on the same rows as
    // the primary's, with no top/bottom margin.
    //
    // Order + indent by tree: a parent precedes its children (DFS pre-order)
    // and each panel's left border is shifted right by its depth, so a child
    // sits under (and indented from) its parent.
    //
    // Min height + scrolling: while every panel fits at [minPanelHeight] the
    // column tiles everything as before. Beyond that, one indicator row is
    // reserved above and below the stack ("↑ N panels above" / "↓ N below"),
    // and only the [_scrollOffset] window of panels is tiled. The panels
    // outside the window park at their VIRTUAL slot — where they'd sit if the
    // column extended past the screen — so focus cycling can navigate onto
    // them by geometry (see [ensureVisible]); nothing paints there.
    final ordered = tree.ordered(spawnedFrames);
    final boxTop = layout.topBorderRow;
    final boxHeight = layout.bottomBorderRow - boxTop + 1;
    final scrolling = ordered.length * minPanelHeight > boxHeight;
    final stackTop = boxTop + (scrolling ? 1 : 0);
    final stackHeight = boxHeight - (scrolling ? 2 : 0);
    final visibleCount = _visibleCapacity(stackHeight, ordered.length);
    if (!scrolling) {
      _scrollOffset = 0;
    } else {
      _scrollOffset = _scrollOffset.clamp(0, ordered.length - visibleCount);
    }
    final perPanel = stackHeight ~/ visibleCount;
    for (var i = 0; i < ordered.length; i++) {
      final frame = ordered[i];
      final slot = scrolling ? i - _scrollOffset : i;
      final indent = indentForDepth(tree.depthOf(frame.conversationId));
      final row = stackTop + slot * perPanel;
      final inWindow = !scrolling ||
          (i >= _scrollOffset && i < _scrollOffset + visibleCount);
      if (!inWindow) {
        // Virtual slot: negative rows above the stack, rows past the screen
        // below it. Same column/width so direction-aware cycling (arrows)
        // scores it as directly below/above the visible stack.
        frame.setOuter(
          Rect(
            row: row,
            col: info.col + indent,
            width: info.width - indent,
            height: perPanel,
          ),
          parked: true,
        );
        continue;
      }
      final h = slot < visibleCount - 1 ? perPanel : stackTop + stackHeight - row;
      frame.setOuter(Rect(
        row: row,
        col: info.col + indent,
        width: info.width - indent,
        height: h.clamp(3, boxHeight),
      ));
      tree.relabelPanel(
          frame, tree.baseLabel[frame.conversationId] ?? frame.label);
    }
    if (scrolling) {
      final hiddenAbove = _scrollOffset;
      final hiddenBelow = ordered.length - (_scrollOffset + visibleCount);
      _drawScrollIndicator(
          row: stackTop - 1,
          text: hiddenAbove > 0 ? '↑ $hiddenAbove panel${hiddenAbove == 1 ? '' : 's'} above' : '');
      _drawScrollIndicator(
          row: stackTop + stackHeight,
          text: hiddenBelow > 0
              ? '↓ $hiddenBelow panel${hiddenBelow == 1 ? '' : 's'} below (Ctrl+W to cycle)'
              : '');
    }
  }

  /// How many of [panelCount] panels fit into [stackHeight] rows: every panel
  /// while they all fit at [minPanelHeight], else that many (at least one, so
  /// a short terminal still shows something rather than a blank column).
  int _visibleCapacity(int stackHeight, int panelCount) {
    if (panelCount <= 1) return panelCount;
    final cap = stackHeight ~/ minPanelHeight;
    return cap < 1 ? 1 : (cap > panelCount ? panelCount : cap);
  }

  /// Scroll the side column's window so [frame] is among the visible panels.
  /// Returns true when the window moved — the caller must then [layout] and
  /// relay content. False when [frame] is unknown, everything already fits, or
  /// it was already in the window.
  bool ensureVisible(PanelFrame frame) {
    final ordered = tree.ordered(spawnedFrames);
    final idx = ordered.indexOf(frame);
    if (idx < 0) return false;
    final layout = screen.layout;
    final boxHeight = layout.bottomBorderRow - layout.topBorderRow + 1;
    if (ordered.length * minPanelHeight <= boxHeight) return false;
    final visibleCount =
        _visibleCapacity(boxHeight - 2, ordered.length); // −2: indicators
    var offset = _scrollOffset;
    if (idx < offset) offset = idx;
    if (idx >= offset + visibleCount) offset = idx - visibleCount + 1;
    offset = offset.clamp(0, ordered.length - visibleCount);
    if (offset == _scrollOffset) return false;
    _scrollOffset = offset;
    return true;
  }

  /// Paint one scroll-indicator row in the right column: dim text at the info
  /// column's left edge, clipped to the column. Rows above/below the panel
  /// stack belong exclusively to the indicators (the stack never tiles into
  /// them), so nothing repaints over these cells.
  void _drawScrollIndicator({required int row, required String text}) {
    if (text.isEmpty) return;
    final info = screen.layout.info;
    if (info.isEmpty) return;
    screen.putAtAbsolute(
      row: row,
      col: info.col,
      text: screen.colorize(screen.theme.chat.dim, text),
      maxCols: info.width,
      moveCursor: false,
    );
  }

  /// Move the shared input line onto [target]'s input rect, saving the editor
  /// state to the previously-active panel and loading [target]'s. [target] is
  /// resolved by the coordinator (which knows the active conversation); this
  /// manager just performs the save/retarget/load so it stays content-agnostic.
  void relocateInput(PanelFrame target, {bool force = false}) {
    if (target == _inputFrame && !force) return;
    // Save current editor state to the old panel — only during an active edit
    // session. Between turns the editor state is empty or stale.
    final oldFrame = _inputFrame;
    if (oldFrame != null && editor.isEditing) {
      final s = editor.editState;
      oldFrame.inputBuffer = s.buffer;
      oldFrame.inputCursor = s.cursor;
      // blur() called render() before we had a chance to save — repaint now so
      // the saved input text is visible on the unfocused panel.
      oldFrame.render();
    }
    // Repoint the shared input region to the new panel's interior first, so the
    // editor's render below parks the cursor in the new panel's input rect
    // rather than the old one (otherwise /spawn leaves the cursor in the main
    // panel's input field while the spawned panel is blue/focused).
    screen.input.setBoundsOverride(target.inputRect);
    _inputFrame = target;
    // Load the new panel's state into the editor (renders + parks cursor).
    editor.loadEditState(target.inputBuffer, target.inputCursor);
  }

  void dispose() {
    primaryFrame.dispose();
    for (final f in spawnedFrames) {
      f.dispose();
    }
    spawnedFrames.clear();
  }
}
