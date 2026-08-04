import 'theme.dart';

/// The busy-border comet — a bright head sweeping a fading truecolor tail
/// along a panel's top and bottom rails while its agent is processing a turn.
///
/// Pure functions, lifted out of the panel so the cell math is unit-testable
/// without a [Screen] / [ConversationPanel] instance. A panel draws the comet
/// by asking [cometRailString] for each rail's run of cells and writing it
/// like any other border text; a per-panel [Timer] advances the tick and
/// repaints the rails.
///
/// Config (head/tail SGR + RGB, tail length) lives on [BusyBorderTheme],
/// reached via `theme.border.busy`.

/// The cell at tail-distance [d] behind the head (0 = the head; a negative
/// [d] is ahead of it). Returns the glyph and its SGR color code, or a plain
/// rail cell (null code) when the head has faded back into the rail.
///
/// The head is a bold bright cyan-white heavy `━`; each trailing cell steps
/// the truecolor RGB toward the rail over [BusyBorderTheme.tailLength] cells.
({String glyph, String? code}) cometCellFor(Theme theme, int d) {
  final busy = theme.border.busy;
  if (d == 0) return (glyph: '━', code: busy.head);
  if (d < 0 || d > busy.tailLength) return (glyph: '─', code: null);
  final t = d / busy.tailLength;
  int ax(int a, int b) => (a + (b - a) * t).round();
  final rgb = [
    ax(busy.headRgb[0], busy.railRgb[0]),
    ax(busy.headRgb[1], busy.railRgb[1]),
    ax(busy.headRgb[2], busy.railRgb[2]),
  ];
  return (glyph: '─', code: '38;2;${rgb[0]};${rgb[1]};${rgb[2]}');
}

/// The head's relative offset within a rail of [span] cells at tick [tick].
/// [shift] offsets the top rail by half the span so the top and bottom heads
/// sweep opposite sides rather than reading as a vertical band.
int cometHeadOffset(int span, int tick, {bool shift = false}) {
  final n = span < 1 ? 1 : span;
  return shift ? (tick + n ~/ 2) % n : tick % n;
}

/// The per-cell comet rendering for a rail of [span] cells at [tick]: the head
/// at [cometHeadOffset], each following cell stepping back along the tail.
List<({String glyph, String? code})> cometRailCells(
  Theme theme,
  int span,
  int tick, {
  bool shift = false,
}) {
  final head = cometHeadOffset(span, tick, shift: shift);
  return [
    for (var i = 0; i < span; i++) cometCellFor(theme, head - i),
  ];
}

/// Build the styled string for a comet rail of [span] cells at [tick].
///
/// Each cell is painted with its own comet color when the comet supplies one
/// (the head + tail); otherwise it falls back to [accent] (the rail tint) or
/// plain. [colorize] is the screen's `colorize(code, text)` so the panel
/// stays free of ANSI specifics.
String cometRailString(
  Theme theme,
  int span,
  int tick,
  String? accent,
  String Function(String code, String text) colorize, {
  bool shift = false,
}) {
  if (span <= 0) return '';
  final cells = cometRailCells(theme, span, tick, shift: shift);
  final b = StringBuffer();
  for (final c in cells) {
    final code = c.code;
    if (code != null) {
      b.write(colorize(code, c.glyph));
    } else if (accent != null) {
      b.write(colorize(accent, c.glyph));
    } else {
      b.write(c.glyph);
    }
  }
  return b.toString();
}
