import 'package:tina_layout/tina_layout.dart';

import 'rect.dart';
import 'screen_layout_strategy.dart';

/// Where every visible region lives, derived from the terminal size.
///
/// Layout model (three panels stacked/tiled below an optional menu strip):
///
///     row 0    menu strip (no border) — present when [hasMenuBar]
///     row 1    ┌── chat ────────────┬── info ─────┐
///     ...      │ scrollback         │ static text │
///     row H-2  │ > prompt input     │             │
///     row H-1  └────────────────────┴─────────────┘
///
/// Chat and info are two independent bordered boxes sharing top and bottom
/// border rows. The chat box owns its input row at the bottom (row H-2) — no
/// separate separator, no external prompt strip. The info box is a passive
/// info surface (see `TextPanel`); it disappears below [splitThreshold] so
/// narrow terminals give the whole width to chat.
///
/// All region rectangles ([chat], [input], [info]) are interior — they
/// exclude the border cells on their box.
/// Requesting a sidebar reserves a narrow box on the left and places the
/// status strip below both boxes, outside their input/content rectangles.
class ScreenLayout {
  /// Terminal width threshold below which the info box vanishes and chat
  /// spans the full width.
  static const int splitThreshold = 100;

  final int width;
  final int height;

  /// True iff the info box is present. Below [splitThreshold] the layout
  /// collapses to just the chat box.
  final bool isSplit;

  /// Whether the info box's border frame is drawn. When false, the info rect
  /// still exists (content can render there) but no border is painted. Set
  /// externally when spawned panels replace the static info panel.
  final bool drawInfoFrame;

  /// Region rectangles — interior of each box.
  final Rect chat;
  final Rect input;
  final Rect info;

  /// Border-inclusive conversation sidebar; empty when not requested.
  final Rect sidebar;

  /// Alias for [info] — kept because callers still say `screen.status`.
  Rect get status => info;

  /// Chat box border columns.
  final int chatLeftCol;
  final int chatRightCol;

  /// Info box border columns. `-1` when [isSplit] is false.
  final int infoLeftCol;
  final int infoRightCol;

  /// Rows where horizontal borders live. Both chat and info share these
  /// rows because the two boxes are the same height.
  final int topBorderRow;
  final int bottomBorderRow;

  /// Row where the prompt lives, inside the chat box just above the strip.
  final int inputRow;

  /// Row where the mode/status strip lives, between input and bottom border.
  final int stripRow;

  /// Whether a menu bar box is reserved at the top of the screen.
  final bool hasMenuBar;

  /// Row of the menu box content (labels) — 1 when present (inside the
  /// bordered box occupying rows 0–2), -1 otherwise.
  final int menuBarRow;

  /// Top border row of the menu box (0 when present, -1 otherwise).
  final int menuTopBorderRow;

  /// Bottom border row of the menu box (2 when present, -1 otherwise).
  final int menuBottomBorderRow;

  /// Backwards-compat: leftmost border column of the whole layout.
  int get leftBorderCol => chatLeftCol;

  /// Backwards-compat: rightmost border column of the whole layout.
  int get rightBorderCol => isSplit ? infoRightCol : chatRightCol;

  /// Backwards-compat: the "divider" column between chat and info in the
  /// old single-outer-frame layout. Maps to the chat's right border here —
  /// callers that used it to check content widths still get a sensible
  /// answer, though semantics differ. Prefer [chatRightCol]/[infoLeftCol]
  /// for new code.
  int get dividerCol => chatRightCol;

  /// Backwards-compat: the old horizontal separator between chat and input
  /// no longer exists — the input lives inside the chat box. Kept as `-1`
  /// so existing callers that gate on "separator present" still branch to
  /// the "no separator" side.
  int get separatorRow => -1;

  const ScreenLayout._({
    required this.width,
    required this.height,
    required this.isSplit,
    this.drawInfoFrame = true,
    required this.chat,
    required this.input,
    required this.info,
    required this.sidebar,
    required this.chatLeftCol,
    required this.chatRightCol,
    required this.infoLeftCol,
    required this.infoRightCol,
    required this.topBorderRow,
    required this.bottomBorderRow,
    required this.inputRow,
    required this.stripRow,
    required this.hasMenuBar,
    required this.menuBarRow,
    required this.menuTopBorderRow,
    required this.menuBottomBorderRow,
  });

  /// Compute the layout for a terminal of [width] cols and [height] rows.
  ///
  /// Policy (size clamps, split threshold, sidebar reservation) is decided
  /// here; the geometry itself is solved by the `tina_layout` grid solver
  /// in square units (1 unit = 1 column x 2 rows, so half-unit tracks are
  /// single rows). Two nested grids reproduce the historical layout:
  ///
  /// * outer — columns `[sidebar?] [chat 65% min 30 | info 35% min 20]`
  ///   (single flexible column when not split); rows
  ///   `[menu 3 rows?] [panel body] [status strip]`.
  /// * inner (chat box) — `[border 1 | interior | border 1]` columns;
  ///   `[top border .5u | transcript 1fr | input row .5u | bottom border
  ///   .5u]` rows. The info box is inset the same way, minus a bottom
  ///   border row (legacy: info content runs through its bottom border).
  ///
  /// Reserves a 3-row bordered menu box at the top (rows 0–2, when
  /// [hasMenuBar]), the chat/info top border row below it, one input row
  /// inside the chat box just above the bottom border, and the bottom border
  /// row.
  factory ScreenLayout.fromSize(int width, int height,
      {bool hasMenuBar = false,
      bool? split,
      bool drawInfoFrame = true,
      int sidebarWidth = 0}) {
    // Policy: clamp the terminal to something usable.
    final w = width < 1 ? 1 : width;
    final minH = hasMenuBar ? 8 : 6;
    final h = height < minH ? minH : height;

    // Policy: sidebar reservation and chat/info split decision.
    final sideWidth = sidebarWidth <= 0 || w < 30
        ? 0
        : sidebarWidth.clamp(10, (w ~/ 3).clamp(10, w - 20));
    final available = w - sideWidth;

    // Policy: the ACTIVE strategy may reshape the template. Native
    // strategies are trusted code (see docs/native-layout-strategies.md):
    // beyond sizing tracks they can flip the split decision, move its
    // threshold, change the weights and mirror the columns. A strategy
    // that is not a [ScreenLayoutStrategy] — or one whose policy
    // throws — changes nothing here (the dispatcher reports the throw).
    ScreenPolicy? policy;
    final strategy = LayoutStrategies.active;
    if (strategy is ScreenLayoutStrategy) {
      try {
        policy = strategy.policyFor(
            width: w,
            height: h,
            hasMenuBar: hasMenuBar,
            sidebarWidth: sideWidth);
      } catch (_) {
        policy = null;
      }
    }
    final minSplit = policy?.minSplitWidth ?? 50;
    final mirrored = policy?.mirror ?? false;
    final isSplit = (((split ?? available >= splitThreshold)) ||
            (policy?.forceSplit ?? false)) &&
        available >= minSplit;

    // -- Outer grid: box-level screen regions ------------------------------
    final chatWeight = policy?.chatWeight ?? 65;
    final infoWeight = policy?.infoWeight ?? 35;
    final chatTrack = sideWidth > 0 ? 1 : 0;
    final columns = <GridTrack>[
      if (sideWidth > 0) GridTrack.fixed(sideWidth.toDouble()),
      if (isSplit) ...[
        if (mirrored)
          GridTrack.weighted(infoWeight.toDouble(), minUnits: 20)
        else
          GridTrack.weighted(chatWeight.toDouble(), minUnits: 30),
        if (mirrored)
          GridTrack.weighted(chatWeight.toDouble(), minUnits: 30)
        else
          GridTrack.weighted(infoWeight.toDouble(), minUnits: 20),
      ] else
        const GridTrack.weighted(1),
    ];
    final rows = <GridTrack>[
      if (hasMenuBar) const GridTrack.fixed(1.5), // bordered menu box
      const GridTrack.weighted(1), // panel boxes, borders included
      const GridTrack.fixed(0.5), // mode/status strip
    ];
    final bodyRow = hasMenuBar ? 1 : 0;
    final stripRowTrack = rows.length - 1;
    // Mirrored layouts put the info box in the first content column.
    final chatColumn = isSplit && mirrored ? chatTrack + 1 : chatTrack;
    final infoColumn = isSplit && mirrored ? chatTrack : chatTrack + 1;
    final screen = LayoutStrategies.solve(
        GridSpec(
            columns: columns,
            rows: rows,
            items: [
              if (hasMenuBar)
                GridItem(
                    id: 'menu',
                    column: TrackSpan.at(0, span: columns.length),
                    row: const TrackSpan.at(0)),
              if (sideWidth > 0)
                GridItem(
                    id: 'sidebar',
                    column: const TrackSpan.at(0),
                    row: TrackSpan.at(bodyRow)),
              GridItem(
                  id: 'chatBox',
                  column: TrackSpan.at(chatColumn),
                  row: TrackSpan.at(bodyRow)),
              if (isSplit)
                GridItem(
                    id: 'infoBox',
                    column: TrackSpan.at(infoColumn),
                    row: TrackSpan.at(bodyRow)),
              GridItem(
                  id: 'strip',
                  column: TrackSpan.at(0, span: columns.length),
                  row: TrackSpan.at(stripRowTrack)),
            ]),
        columns: w,
        rows: h);
    final chatBox = screen.rectOf('chatBox')!;
    final infoBox = isSplit ? screen.rectOf('infoBox')! : null;
    final strip = screen.rectOf('strip')!;
    final menu = screen.rectOf('menu');

    // -- Inner grid: chat box interior (transcript + input) ----------------
    final chatInterior = _solveInterior(chatBox.width, chatBox.height,
        bottomBorder: true);
    final transcript = chatInterior[0]!;
    final input = chatInterior[1]!;
    final chat = Rect(
      row: chatBox.row + transcript.row,
      col: chatBox.col + transcript.col,
      width: transcript.width,
      height: transcript.height,
    );
    final inputRect = Rect(
      row: chatBox.row + input.row,
      col: chatBox.col + input.col,
      width: input.width,
      height: input.height,
    );

    // -- Inner grid: info box interior --------------------------------------
    // Legacy: the info content area spans from the top border row + 1 to
    // the strip row - 1 — through the box's bottom border row (no input
    // row, no bottom inset). Non-split layouts have no info box at all.
    var info = Rect.empty;
    if (isSplit) {
      final infoInterior =
          _solveInterior(infoBox!.width, infoBox.height, bottomBorder: false);
      final content = infoInterior[0]!;
      info = Rect(
        row: infoBox.row + content.row,
        col: infoBox.col + content.col,
        width: content.width,
        height: content.height,
      );
    }

    return ScreenLayout._(
      width: w,
      height: h,
      isSplit: isSplit,
      drawInfoFrame: drawInfoFrame,
      chat: chat,
      input: inputRect,
      info: info,
      sidebar: sideWidth == 0
          ? Rect.empty
          : () {
              final sb = screen.rectOf('sidebar')!;
              return Rect(
                  row: sb.row,
                  col: sb.col,
                  width: sb.width,
                  height: sb.height);
            }(),
      chatLeftCol: chatBox.col,
      chatRightCol: chatBox.col + chatBox.width - 1,
      infoLeftCol: isSplit ? infoBox!.col : -1,
      infoRightCol: isSplit ? infoBox!.col + infoBox.width - 1 : -1,
      topBorderRow: chatBox.row,
      bottomBorderRow: chatBox.row + chatBox.height - 1,
      inputRow: inputRect.row,
      stripRow: strip.row,
      hasMenuBar: hasMenuBar,
      menuBarRow: hasMenuBar ? menu!.row + 1 : -1,
      menuTopBorderRow: hasMenuBar ? menu!.row : -1,
      menuBottomBorderRow: hasMenuBar ? menu!.row + menu.height - 1 : -1,
    );
  }

  /// Solve a panel box interior: `[border | content | border]` columns and,
  /// with [bottomBorder], `[top .5u | content 1fr | input .5u | bottom .5u]`
  /// rows; without it `[top .5u | content 1fr]` (the info box model).
  /// Returns `(content, input)` — `input` is empty without [bottomBorder].
  static List<GridRect?> _solveInterior(int width, int height,
      {required bool bottomBorder}) {
    final solution = LayoutStrategies.solve(
        GridSpec(
            columns: const [
              GridTrack.fixed(1),
              GridTrack.weighted(1),
              GridTrack.fixed(1),
            ],
            rows: bottomBorder
                ? const [
                    GridTrack.fixed(0.5),
                    GridTrack.weighted(1),
                    GridTrack.fixed(0.5),
                    GridTrack.fixed(0.5),
                  ]
                : const [
                    GridTrack.fixed(0.5),
                    GridTrack.weighted(1),
                  ],
            items: [
              const GridItem(
                  id: 'content',
                  column: TrackSpan.at(1),
                  row: TrackSpan.at(1)),
              if (bottomBorder)
                const GridItem(
                    id: 'input', column: TrackSpan.at(1), row: TrackSpan.at(2)),
            ]),
        columns: width,
        rows: height);
    return [solution.rectOf('content'), solution.rectOf('input')];
  }

  /// Cell content for the border cell at ([row], [col]), or `null` if that
  /// cell isn't part of any panel's border. Used by the frame painter and
  /// [Screen]'s per-write border repair. The chat area's border is panel-drawn
  /// ([ConversationPanel]), so only the (dormant) menu and info boxes are
  /// described here.
  String? borderCharFor(int row, int col) {
    // Menu box — full width, rows 0–2 when present.
    if (hasMenuBar) {
      if (row == menuTopBorderRow) {
        if (col == 0) return '┌';
        if (col == width - 1) return '┐';
        return '─';
      }
      if (row == menuBottomBorderRow) {
        if (col == 0) return '└';
        if (col == width - 1) return '┘';
        return '─';
      }
      if (row == menuBarRow) {
        if (col == 0 || col == width - 1) return '│';
        return null; // interior — labels live here
      }
    }
    // Info box corners (split + drawn info frame only).
    if (isSplit && drawInfoFrame) {
      if (row == topBorderRow) {
        if (col == infoLeftCol) return '┌';
        if (col == infoRightCol) return '┐';
      }
      if (row == bottomBorderRow) {
        if (col == infoLeftCol) return '└';
        if (col == infoRightCol) return '┘';
      }
      if (row > topBorderRow && row < bottomBorderRow) {
        if (col == infoLeftCol || col == infoRightCol) return '│';
      }
    }
    return null;
  }

  /// Whether [col] is a border column of either panel.
  bool isBorderColumn(int col) =>
      col == chatLeftCol ||
      col == chatRightCol ||
      (isSplit && (col == infoLeftCol || col == infoRightCol));

  /// Whether [row] is one of the shared horizontal border rows.
  bool isHorizontalBorderRow(int row) =>
      row == topBorderRow || row == bottomBorderRow;
}
