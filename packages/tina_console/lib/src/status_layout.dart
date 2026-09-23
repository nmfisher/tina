import 'renderer.dart';
import 'term_width.dart';

/// Inputs to a status strip layout: everything the strip could show, plus the
/// width it must fit within. Pure data — no screen, backend or conversation
/// state — so layouts are testable in isolation and plugins can swap them.
class StatusContent {
  /// The host-owned permission-mode label (`mode: ask`), or null when the
  /// host shows none. Layouts decide whether and where it appears; the
  /// default paints it first on the left, dim.
  final String? modeLabel;

  /// Plugin status lines, in registration order, after their renderers ran.
  final List<RenderLine> lines;

  const StatusContent({this.modeLabel, this.lines = const []});
}

/// Arranges [StatusContent] into the lines the strip paints. A pure function
/// of content and width — the host owns painting and geometry (which row the
/// strip occupies), so a layout decides placement within the row, grouping,
/// and what to drop under width pressure; never where the strip itself sits.
///
/// Lines the layout returns keep their [RenderLine.align]: `right`-aligned
/// lines anchor to the strip's right edge, everything else flows from the
/// left. Returning the content's lines unchanged is a valid no-op layout.
abstract interface class StatusLayout {
  List<RenderLine> arrange(StatusContent content, int width);
}

/// The identity layout: the mode label plus every plugin line, left-aligned
/// in one row, joined with `'  │  '` — byte-for-byte the strip's behavior
/// before layouts existed. Clips only when the joined row exceeds [width].
class DefaultStatusLayout implements StatusLayout {
  const DefaultStatusLayout();

  @override
  List<RenderLine> arrange(StatusContent content, int width) {
    if (width <= 0) return const [];
    return [
      if (content.modeLabel != null && content.modeLabel!.isNotEmpty)
        RenderLine(runs: [RenderRun(content.modeLabel!, '2')]),
      ...content.lines,
    ];
  }
}

/// Visible width of a line's runs, ignoring style codes — layout arithmetic
/// for plugins that measure before deciding what to keep.
int statusLineWidth(RenderLine line) {
  var w = 0;
  for (final run in line.runs) {
    for (var i = 0; i < run.text.length;) {
      final size = runeSizeAt(run.text, i);
      w += runeWidth(codePointAt(run.text, i));
      i += size;
    }
  }
  return w;
}
