import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';

/// Strip renderer for the background release check.
///
/// `checking` paints a spinning `update check |` line (animated so the strip's
/// 120ms ticker drives it); `updateAvailable` paints a persistent alert —
/// `update ⬆ v0.9.0 · /update` — in the theme's yellow so it reads as a
/// warning-style indicator among the left-aligned group. Idle (the check has
/// settled up-to-date or missed) is declined by the source, so the renderer
/// never sees it.
class VersionStatusRenderer extends Renderer<VersionSnapshot> {
  const VersionStatusRenderer();

  static const _frames = ['|', '/', '-', '\\'];

  @override
  List<RenderLine> render(VersionSnapshot value, RenderContext context) {
    return switch (value.phase) {
      VersionPhase.checking => [
          RenderLine(
            animated: true,
            runs: [
              RenderRun(
                'update check ${_frames[context.animationFrame % _frames.length]}',
                context.theme.chat.dim,
              ),
            ],
          ),
        ],
      // Left-aligned by default: the strip's single right-aligned group
      // belongs to the token counter, so this never competes for the tail.
      VersionPhase.updateAvailable => [
          RenderLine(
            runs: [
              RenderRun('update ', context.theme.chat.dim),
              RenderRun('⬆ ${value.tag!} · /update', context.theme.chat.yellow),
            ],
          ),
        ],
    };
  }
}
