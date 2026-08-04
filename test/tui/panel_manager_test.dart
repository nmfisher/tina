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
      final pm = PanelManager(
        screen: screen,
        focusManager: focusManager,
        editor: editor,
        primaryFrame: primary,
        terminalGeometry: geometry,
        menuBarEnabled: false,
        tree: tree,
      );
      final a = _spawn('a');
      final b = _spawn('b');
      final c = _spawn('c');
      pm.addFrame(a);
      pm.addFrame(b);
      pm.addFrame(c);

      // Adding frames must not lay out on its own — geometry is an explicit
      // call (so the coordinator can batch add + layout). The panels stay at
      // their constructed (empty) rects until layout() runs.
      expect(a.bounds.isEmpty, isTrue);
      pm.layout();

      final layout = screen.layout;
      expect(layout.isSplit, isTrue);
      final ordered = tree.ordered(pm.spawnedFrames);
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
