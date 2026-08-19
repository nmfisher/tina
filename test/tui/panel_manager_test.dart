import 'package:tina/tui_coordinator.dart' show SpawnTree;
import 'package:tina/tui/panel_manager.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina/platform/terminal_geometry.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// Content-agnostic unit tests for [PanelManager]: the geometry + focus-ring
/// seams that Phase 3 extracted out of [TuiCoordinator.create]. Driving
/// [PanelManager] directly (no coordinator, no overlays, no chat) is the point
/// of the extraction — the behavior used to be buried in create()-local
/// closures that could only be exercised through the full run() path.
///
/// Input *relocation* ([PanelManager.relocateInput]) is intentionally NOT
/// covered here: it is pinned end-to-end by the `relocateInput repoints the
/// shared input region` characterization test in tui_coordinator_test.dart,
/// which threads the real focus path through run(). A content-agnostic manager
/// can't assert save/restore of editor state without an edit session, so that
/// behavior stays a coordinator-level assertion.
void main() {
  // A split layout yields a right-hand info column the spawned panels live in;
  // no info frame, since panels self-draw their own borders. 120x24 matches the
  // coordinator characterization test so geometry numbers are comparable.
  late FakeStdio io;
  late Screen screen;
  late FocusManager focusManager;
  late LineEditor editor;
  late PanelFrame primary;
  late SpawnTree tree;
  late TerminalGeometry geometry;

  setUp(() {
    io = FakeStdio()..columns = 120;
    final layout = ScreenLayout.fromSize(120, 24,
        split: true, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    focusManager = FocusManager();
    editor = LineEditor(screen: screen);
    primary = PanelFrame(
      screen: screen,
      label: 'primary',
      conversationId: 'primary',
    )..setReservesInput(true);
    tree = SpawnTree(rootId: primary.conversationId);
    geometry = _Geometry(columns: 120, lines: 24);
  });

  PanelFrame _spawn(String id, {String parent = 'primary'}) {
    final panel = PanelFrame(
      screen: screen,
      label: id,
      conversationId: id,
    )..setReservesInput(true);
    tree.parentOf[id] = parent;
    tree.baseLabel[id] = id;
    return panel;
  }

  group('layout (geometry)', () {
    test('no spawned frames: primary owns the full chat width', () {
      final pm = PanelManager(
        screen: screen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: primary,
        terminalGeometry: geometry,
        menuBarEnabled: false,
        tree: tree,
      );
      pm.layout();
      final layout = screen.layout;
      // Primary spans the full chat box (chatLeftCol .. chatRightCol) and the
      // box's full height.
      expect(primary.bounds.row, layout.topBorderRow);
      expect(primary.bounds.col, layout.chatLeftCol);
      expect(primary.bounds.width,
          layout.chatRightCol - layout.chatLeftCol + 1);
      expect(primary.bounds.height,
          layout.bottomBorderRow - layout.topBorderRow + 1);
      pm.dispose();
    });

    test('spawned panels tile the right column: perPanel height, last absorbs '
        'the remainder, contiguous and aligned', () {
      // A tall screen so every panel fits at the column's minimum height —
      // the tiling math under test is the fit case; the scroll case has its
      // own group below.
      final tallIo = FakeStdio()..columns = 120;
      final tallScreen = Screen(
          io: tallIo,
          layout: ScreenLayout.fromSize(120, 44, split: true, drawInfoFrame: false),
          ansi: AnsiCapable.yes);
      final tallPrimary = PanelFrame(
        screen: tallScreen,
        label: 'primary',
        conversationId: 'primary',
      )..setReservesInput(true);
      final tallTree = SpawnTree(rootId: tallPrimary.conversationId);
      final pm = PanelManager(
        screen: tallScreen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: tallPrimary,
        terminalGeometry: _Geometry(columns: 120, lines: 44),
        menuBarEnabled: false,
        tree: tallTree,
      );
      PanelFrame spawn(String id) {
        final panel = PanelFrame(
          screen: tallScreen,
          label: id,
          conversationId: id,
        )..setReservesInput(true);
        tallTree.parentOf[id] = 'primary';
        tallTree.baseLabel[id] = id;
        return panel;
      }

      final a = spawn('a');
      final b = spawn('b');
      final c = spawn('c');
      pm.addFrame(a);
      pm.addFrame(b);
      pm.addFrame(c);

      // Adding frames must not lay out on its own — geometry is an explicit
      // call (so the coordinator can batch add + layout). The panels stay at
      // their constructed (empty) rects until layout() runs.
      expect(a.bounds.isEmpty, isTrue);
      pm.layout();

      final layout = tallScreen.layout;
      expect(layout.isSplit, isTrue);
      final ordered = tallTree.ordered(pm.spawnedFrames);
      expect(ordered, hasLength(3));

      final boxTop = layout.topBorderRow;
      final boxHeight = layout.bottomBorderRow - boxTop + 1;
      final perPanel = boxHeight ~/ ordered.length;

      // First panel's top aligns with the primary's top border row.
      expect(ordered.first.bounds.row, boxTop,
          reason: 'first panel starts at the box top');
      // Every panel is perPanel tall except the last, which absorbs the
      // remainder so the column is fully covered with no gap or overlap.
      for (var i = 0; i < ordered.length; i++) {
        final p = ordered[i];
        final expectedH = i < ordered.length - 1
            ? perPanel
            : boxTop + boxHeight - p.bounds.row;
        expect(p.bounds.height, expectedH, reason: 'panel $i height');
      }
      // Contiguity: each panel begins exactly where the previous ended.
      for (var i = 0; i < ordered.length - 1; i++) {
        expect(ordered[i + 1].bounds.row,
            ordered[i].bounds.row + ordered[i].bounds.height,
            reason: 'panel $i is contiguous with the next');
      }
      // Full vertical coverage: last panel bottom reaches the box bottom.
      final last = ordered.last;
      expect(last.bounds.row + last.bounds.height, boxTop + boxHeight,
          reason: 'panels fill the box top-to-bottom');
      // Flat spawns share one depth, so they share the same left col/width
      // (same indent under the info box).
      final col0 = ordered.first.bounds.col;
      final w0 = ordered.first.bounds.width;
      for (final p in ordered) {
        expect(p.bounds.col, col0, reason: 'flat spawns share indent');
        expect(p.bounds.width, w0, reason: 'flat spawns share width');
      }
      pm.dispose();
      tallPrimary.dispose();
    });

    test('nested spawn is indented deeper than its parent', () {
      final pm = PanelManager(
        screen: screen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: primary,
        terminalGeometry: geometry,
        menuBarEnabled: false,
        tree: tree,
      );
      final child = _spawn('child', parent: 'parent');
      final parent = _spawn('parent');
      pm.addFrame(parent);
      pm.addFrame(child);
      pm.layout();

      // The child (depth 2) sits 2 columns right of the parent (depth 1).
      expect(tree.depthOf('parent'), 1);
      expect(tree.depthOf('child'), 2);
      expect(child.bounds.col, greaterThan(parent.bounds.col),
          reason: 'child is indented right of its parent');
      pm.dispose();
    });

    test('applyScreenLayout resizes the screen to the split/no-split layout',
        () {
      // Full-width (no split) initially: the info column is absent.
      final fullWidth = ScreenLayout.fromSize(120, 24, split: false);
      screen.resize(fullWidth);
      expect(screen.layout.isSplit, isFalse);

      final pm = PanelManager(
        screen: screen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: primary,
        terminalGeometry: geometry,
        menuBarEnabled: false,
        tree: tree,
      );

      // First spawn splits the layout to make a right column.
      pm.applyScreenLayout(split: true, drawInfoFrame: false);
      expect(screen.layout.isSplit, isTrue,
          reason: 'split opens the right (info) column');

      // A no-split transition collapses it back.
      pm.applyScreenLayout(split: false, drawInfoFrame: true);
      expect(screen.layout.isSplit, isFalse,
          reason: 'no-split drops the right column');

      // Width carries through.
      expect(screen.layout.width, 120);
      pm.dispose();
    });
  });

  group('focus ring (addFrame / removeFrame)', () {
    test('addFrame registers the panel so it can receive focus', () {
      final pm = PanelManager(
        screen: screen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: primary,
        terminalGeometry: geometry,
        menuBarEnabled: false,
        tree: tree,
      );
      focusManager.register(primary);
      final a = _spawn('a');
      pm.addFrame(a);

      // The spawned panel is now in the ring and can be focused directly.
      focusManager.focusPanel(a);
      expect(focusManager.focused, a, reason: 'a is reachable in the ring');
      pm.dispose();
    });

    test('removeFrame unregisters the panel from the ring', () {
      final pm = PanelManager(
        screen: screen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: primary,
        terminalGeometry: geometry,
        menuBarEnabled: false,
        tree: tree,
      );
      focusManager.register(primary);
      final a = _spawn('a');
      pm.addFrame(a);
      focusManager.focusPanel(a);
      expect(focusManager.focused, a);

      pm.removeFrame(a);
      // a held focus when it was removed, so the ring is now empty of focus —
      // the previously-focused panel is gone and can never be refocused.
      expect(focusManager.focused, isNull,
          reason: 'removing the focused panel clears focus');
      // Focusing the removed panel is a no-op (it's not in the ring); primary
      // remains the reachable target.
      focusManager.focusPanel(primary);
      expect(focusManager.focused, primary);
      focusManager.focusPanel(a);
      expect(focusManager.focused, isNot(a),
          reason: 'a must not be refocusable after removal');
      pm.dispose();
    });

    test('hasSpawnedFrames reflects the panel list', () {
      final pm = PanelManager(
        screen: screen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: primary,
        terminalGeometry: geometry,
        menuBarEnabled: false,
        tree: tree,
      );
      expect(pm.hasSpawnedFrames, isFalse);
      final a = _spawn('a');
      pm.addFrame(a);
      expect(pm.hasSpawnedFrames, isTrue);
      pm.removeFrame(a);
      expect(pm.hasSpawnedFrames, isFalse);
      pm.dispose();
    });
  });

  group('min height + column scrolling', () {
    // The setUp screen is 120x24 → boxHeight 24: at minPanelHeight 10 that
    // fits two panels unscrolled, and scrolls from four on.
    PanelManager manager(List<PanelFrame> panels) {
      final pm = PanelManager(
        screen: screen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: primary,
        terminalGeometry: geometry,
        menuBarEnabled: false,
        tree: tree,
      );
      for (final p in panels) {
        pm.addFrame(p);
      }
      return pm;
    }

    test('panels that fit are each at least minPanelHeight tall', () {
      final pm = manager([_spawn('a'), _spawn('b')]);
      pm.layout();
      // 2 × 10 ≤ 24 → no scrolling; equal tiling at 12 each.
      for (final p in pm.spawnedFrames) {
        expect(p.bounds.isEmpty, isFalse);
        expect(p.bounds.height,
            greaterThanOrEqualTo(PanelManager.minPanelHeight));
      }
      pm.dispose();
    });

    test('excess panels scroll: only the window tiles, the rest park',
        () {
      final panels = [_spawn('a'), _spawn('b'), _spawn('c'), _spawn('d')];
      final pm = manager(panels);
      pm.layout();

      // 24 rows − 2 indicator rows = 22 → capacity 2 at min height.
      final visible = panels.where((p) => !p.isParked).toList();
      expect(visible, hasLength(2), reason: 'only the window is tiled');
      expect(visible, [panels[0], panels[1]],
          reason: 'the window starts at the top of the order');
      for (final p in visible) {
        expect(p.bounds.isEmpty, isFalse);
        expect(p.bounds.height,
            greaterThanOrEqualTo(PanelManager.minPanelHeight));
      }
      // Parked panels paint nothing but keep a VIRTUAL slot with real
      // geometry, so focus cycling can navigate onto them by direction.
      for (final p in panels.skip(2)) {
        expect(p.isParked, isTrue);
        expect(p.bounds.isEmpty, isFalse,
            reason: 'parked panels keep virtual geometry for cycling');
        expect(p.canFocus, isTrue,
            reason: 'parked panels stay cyclable (the highlight scrolls them '
                'into view)');
        expect(p.bounds.row, greaterThan(visible.last.bounds.bottom),
            reason: 'a panel hidden below parks below the visible stack');
      }
      // The visible window still covers the stack contiguously.
      expect(visible[1].bounds.row,
          visible[0].bounds.row + visible[0].bounds.height);
      pm.dispose();
    });

    test('ensureVisible scrolls the window to an off-screen panel', () {
      final panels = [_spawn('a'), _spawn('b'), _spawn('c'), _spawn('d')];
      final pm = manager(panels);
      pm.layout();

      // Cycling down to the last panel scrolls it into view…
      expect(pm.ensureVisible(panels[3]), isTrue);
      pm.layout();
      final visible = panels.where((p) => !p.isParked).toList();
      expect(visible, [panels[2], panels[3]],
          reason: 'the window slid down one slot');
      // …and the panels that scrolled off park at virtual slots.
      expect(panels[0].isParked, isTrue);
      expect(panels[1].isParked, isTrue);
      // A panel parked ABOVE the window sits above the visible stack.
      expect(panels[0].bounds.bottom,
          lessThan(visible.first.bounds.row));

      // Already-visible panels don't move the window.
      expect(pm.ensureVisible(panels[2]), isFalse);
      // Cycling back up to the first scrolls the window back.
      expect(pm.ensureVisible(panels[0]), isTrue);
      pm.layout();
      expect(panels[0].isParked, isFalse);
      pm.dispose();
    });

    test('removing panels clamps the scroll offset back into range', () {
      final panels = [_spawn('a'), _spawn('b'), _spawn('c'), _spawn('d')];
      final pm = manager(panels);
      pm.layout();
      expect(pm.ensureVisible(panels[3]), isTrue);
      pm.layout();

      // The window's last two panels close: the offset must clamp so the
      // remaining panels fill the column instead of showing nothing.
      pm.removeFrame(panels[3]);
      pm.removeFrame(panels[2]);
      pm.layout();
      for (final p in pm.spawnedFrames) {
        expect(p.isParked, isFalse,
            reason: 'two panels fit; nothing stays parked');
      }
      pm.dispose();
    });

    test('arrow cycling down onto a parked panel scrolls it into view', () {
      // Regression: parked panels used to drop to Rect.empty, which the
      // focus manager's direction search skips (empty bounds) — the ↓ key
      // could never highlight them, so the column never scrolled. Parked
      // panels now keep virtual geometry, and the highlight hook (what the
      // coordinator wires to ensureVisible + layout) reveals them.
      final panels = [_spawn('a'), _spawn('b'), _spawn('c'), _spawn('d')];
      final pm = manager(panels);
      pm.layout();
      focusManager.register(primary);
      focusManager.home = primary;

      // Wire the coordinator's highlight contract: onHighlight scrolls.
      for (final p in panels) {
        p.onHighlight = () {
          if (pm.ensureVisible(p)) pm.layout();
        };
      }

      // Enter cycling on the top panel and walk DOWN past the window.
      focusManager.focusPanel(panels[0]);
      focusManager.engage();
      focusManager.moveHighlightDirection(ArrowDirection.down);
      expect(focusManager.highlighted, panels[1]);
      focusManager.moveHighlightDirection(ArrowDirection.down);
      // ↓ from the last VISIBLE panel must land on the parked panel below —
      // and the hook must have scrolled the window to show it.
      expect(focusManager.highlighted, panels[2],
          reason: 'arrow cycling crosses the window edge');
      expect(panels[2].isParked, isFalse,
          reason: 'the highlight hook scrolled it into view');

      // Committing focus on it works: it is real, visible geometry now.
      focusManager.commit();
      expect(focusManager.focused, panels[2]);
      expect(panels[2].bounds.isEmpty, isFalse);

      // Tab cycling also reaches parked panels.
      focusManager.engage();
      focusManager.moveHighlightCyclic(1); // → panels[3] (parked, below)
      expect(focusManager.highlighted, panels[3]);
      expect(panels[3].isParked, isFalse,
          reason: 'Tab onto a parked panel scrolls it into view too');
      focusManager.cancel();
      pm.dispose();
    });
  });
}

/// A minimal [TerminalGeometry] backed by fixed columns/lines for tests.
class _Geometry implements TerminalGeometry {
  _Geometry({required this.columns, required this.lines});

  @override
  final int columns;

  @override
  final int lines;

  @override
  bool get hasTerminal => false;
}
