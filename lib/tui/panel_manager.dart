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
    final ordered = tree.ordered(spawnedFrames);
    final boxTop = layout.topBorderRow;
    final boxHeight = layout.bottomBorderRow - boxTop + 1;
    final perPanel = boxHeight ~/ ordered.length;
    for (var i = 0; i < ordered.length; i++) {
      final frame = ordered[i];
      final indent = indentForDepth(tree.depthOf(frame.conversationId));
      final row = boxTop + i * perPanel;
      final h = i < ordered.length - 1 ? perPanel : boxTop + boxHeight - row;
      frame.setOuter(Rect(
        row: row,
        col: info.col + indent,
        width: info.width - indent,
        height: h.clamp(3, boxHeight),
      ));
      tree.relabelPanel(
          frame, tree.baseLabel[frame.conversationId] ?? frame.label);
    }
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
