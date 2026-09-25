import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';

/// Strip renderer for the background release check.
///
/// `checking` paints a spinning `update check |` line (animated so the strip's
/// 120ms ticker drives it); `updateAvailable` paints a persistent alert —
/// `update ⬆ v0.9.0 · /update` — in the theme's yellow so it reads as a
/// warning-style indicator among the left-aligned group; `miss` paints a dim
/// one-liner so a failed check never reads as "up to date". Idle (the check
/// has settled up-to-date) is declined by the source, so the renderer never
/// sees it.
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
      // A failed check is visible but never alarm-colored: dim, one line, a
      // short reason (plus the last known tag when one is cached, so the
      // reader can gauge how stale "no news" is). `/update` remains the path
      // to a definitive answer.
      VersionPhase.miss => [
          RenderLine(
            runs: [
              RenderRun('update check failed — ', context.theme.chat.dim),
              RenderRun(value.why ?? 'unknown reason', context.theme.chat.dim),
              if (value.previousTag != null)
                RenderRun(' · last known ${value.previousTag}',
                    context.theme.chat.dim),
            ],
          ),
        ],
      // A skipped probe is the quietest state: dim, no alarm, no nag — the
      // miss announced itself the session it happened. The strip line keeps
      // the fact visible (deadline + last known tag) without repainting it
      // into the chat transcript every launch.
      VersionPhase.deferred => [
          RenderLine(
            runs: [
              RenderRun('update check deferred', context.theme.chat.dim),
              if (value.until != null)
                RenderRun(
                    ' · retry ${_shortTime(value.until!)}',
                    context.theme.chat.dim),
              if (value.previousTag != null)
                RenderRun(' · last known ${value.previousTag}',
                    context.theme.chat.dim),
            ],
          ),
        ],
    };
  }

  /// `retry 14:05` — a defer deadline has no business spelling dates.
  static String _shortTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
