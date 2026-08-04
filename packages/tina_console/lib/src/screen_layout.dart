import 'rect.dart';

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

  /// Row where the prompt lives, inside the chat box just above the bottom
  /// border.
  final int inputRow;

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
    required this.chatLeftCol,
    required this.chatRightCol,
    required this.infoLeftCol,
    required this.infoRightCol,
    required this.topBorderRow,
    required this.bottomBorderRow,
    required this.inputRow,
    required this.hasMenuBar,
    required this.menuBarRow,
    required this.menuTopBorderRow,
    required this.menuBottomBorderRow,
  });

  /// Compute the layout for a terminal of [width] cols and [height] rows.
  ///
  /// Reserves a 3-row bordered menu box at the top (rows 0–2, when
  /// [hasMenuBar]), the chat/info top border row below it, one input row
  /// inside the chat box just above the bottom border, and the bottom border
  /// row.
  factory ScreenLayout.fromSize(int width, int height,
      {bool hasMenuBar = false, bool? split, bool drawInfoFrame = true}) {
    final w = width < 1 ? 1 : width;
    final minH = hasMenuBar ? 8 : 5;
    final h = height < minH ? minH : height;
    final menuOffset = hasMenuBar ? 3 : 0; // menu box = border/content/border

    final topBorder = menuOffset; // 3 with menu, 0 without.
    final bottomBorder = h - 1;
    final inputRow = h - 2;

    // Menu box geometry (rows 0–2 when present).
    final menuTop = hasMenuBar ? 0 : -1;
    final menuContent = hasMenuBar ? 1 : -1;
    final menuBottom = hasMenuBar ? 2 : -1;

    final isSplit = split ?? w >= splitThreshold;
    final chatWidth = isSplit ? (w * 0.65).round().clamp(30, w - 20) : w;
    final infoWidth = isSplit ? w - chatWidth : 0;

    final chatLeftCol = 0;
    final chatRightCol = chatWidth - 1;
    final infoLeftCol = isSplit ? chatWidth : -1;
    final infoRightCol = isSplit ? w - 1 : -1;

    // Chat scrollback: rows between top border and input row, inside the
    // vertical borders. Height is inputRow - (topBorder+1), which can be
    // zero when the terminal is very short (still valid — no crash, just
    // no room for content).
    final chatContentTop = topBorder + 1;
    final chatContentHeight = inputRow - chatContentTop;
    final chat = Rect(
      row: chatContentTop,
      col: chatLeftCol + 1,
      width: chatWidth - 2,
      height: chatContentHeight < 0 ? 0 : chatContentHeight,
    );

    final input = Rect(
      row: inputRow,
      col: chatLeftCol + 1,
      width: chatWidth - 2,
      height: 1,
    );

    // Info content spans from the top border row+1 to the bottom border-1
    // — it does NOT reserve an input row because the info box has none.
    final infoContentHeight = bottomBorder - topBorder - 1;
    final info = isSplit
        ? Rect(
            row: topBorder + 1,
            col: infoLeftCol + 1,
            width: infoWidth - 2,
            height: infoContentHeight < 0 ? 0 : infoContentHeight,
          )
        : Rect.empty;

    return ScreenLayout._(
      width: w,
      height: h,
      isSplit: isSplit,
      drawInfoFrame: drawInfoFrame,
      chat: chat,
      input: input,
      info: info,
      chatLeftCol: chatLeftCol,
      chatRightCol: chatRightCol,
      infoLeftCol: infoLeftCol,
      infoRightCol: infoRightCol,
      topBorderRow: topBorder,
      bottomBorderRow: bottomBorder,
      inputRow: inputRow,
      hasMenuBar: hasMenuBar,
      menuBarRow: menuContent,
      menuTopBorderRow: menuTop,
      menuBottomBorderRow: menuBottom,
    );
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
