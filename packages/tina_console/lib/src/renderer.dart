import 'theme.dart';

/// Inputs to a pure UI renderer. No screen, input loop or conversation state.
class RenderContext {
  final int width;
  final Theme theme;

  /// Animation step supplied by hosts that support animated rendering.
  final int animationFrame;

  const RenderContext(
      {required this.width, required this.theme, this.animationFrame = 0});
}

/// One span of text with an optional inline SGR style.
class RenderRun {
  final String text;
  final String? code;

  const RenderRun(this.text, this.code);
}

/// A visual row with optional background/row styling. Renderers lay out their
/// rows within RenderContext.width; the host owns painting and scrolling.
class RenderLine {
  final String? bar;

  /// How the host should place this row when a surface offers more than one
  /// position. `null` and [StatusAlign.left] behave identically: flush left.
  final StatusAlign? align;
  final List<RenderRun> runs;

  /// Request another render with an advanced animation frame in status hosts.
  final bool animated;

  const RenderLine({this.bar, this.align, this.runs = const [], this.animated = false});
  const RenderLine.blank()
      : bar = null,
        align = null,
        animated = false,
        runs = const [];

  bool get isBlank => bar == null && runs.every((run) => run.text.isEmpty);
}

/// Where a surface places a [RenderLine] among peers.
enum StatusAlign { left, right }

/// Renders any UI value of type T, including non-message data. Return null to
/// decline a value (for example, a particular block kind); an empty list hides
/// it. Rendering is synchronous and must not mutate the value or perform I/O.
/// The host may call this repeatedly for updates, resize and selection.
abstract class Renderer<T extends Object> {
  const Renderer();

  List<RenderLine>? render(T value, RenderContext context);

  /// Dispatch heterogeneous plugin contributions without unchecked input casts.
  List<RenderLine>? tryRender(Object value, RenderContext context) =>
      value is T ? render(value, context) : null;
}
