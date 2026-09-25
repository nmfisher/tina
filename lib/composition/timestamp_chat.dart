import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../chat/chat_renderer.dart';
import '../chat/chat_transcript.dart';

/// Optional plugin that stamps each transcript block's first painted line with
/// the time the block first appeared (`HH:mm:ss `, dim). Decorates rather than
/// replaces the built-in look: because the first registered renderer that
/// handles a `ChatBlock` wins, this descriptor's id sorts before
/// `tina.chat-renderer` (plain namespace, per the override recipe in
/// docs/features/renderers.md) and then delegates to [ChatRenderer] itself, so
/// output matches the default row for row — only the gutter differs.
///
/// Where the time comes from: neither `ChatBlock` nor `RenderContext` carries
/// a clock, and `render` runs again on every resize, fold and repaint. The
/// renderer therefore memoizes the *first* render time per block instance in
/// an [Expando] — blocks are append-only and painted the moment they are
/// created (`ChatAgentSink._add`), so first render ≈ creation time, and every
/// later repaint of that instance reuses the same stamp instead of drifting
/// with `DateTime.now()`. The [Expando] holds keys weakly, so a cleared
/// transcript releases its stamps with its blocks.
///
/// Known limit: `replayHistory` rebuilds all blocks at resume time and stored
/// messages carry no per-message timestamp, so a resumed conversation's lines
/// are stamped with resume time rather than their original times.
PluginDescriptor timestampChatPlugin({DateTime Function()? now}) =>
    PluginDescriptor(
      // Must sort before `tina.chat-renderer` (`example.` < `tina.`): an id
      // sorting after the built-in would only see blocks it declines — none.
      id: 'example.timestamp-chat',
      factory: FnPluginFactory((context) {
        final renderer = TimestampChatRenderer(now: now ?? DateTime.now);
        context.register(renderer, id: 'example.timestamp-chat.renderer');
        return renderer;
      }),
    );

/// [ChatRenderer] wrapped with a fixed-width dim time gutter on every
/// non-blank line. Pure presentation; see [timestampChatPlugin] for the
/// stamping model.
class TimestampChatRenderer extends Renderer<ChatBlock> {
  TimestampChatRenderer({required DateTime Function() now}) : _now = now;

  final DateTime Function() _now;

  /// First-render time per block instance. Weak keys: entries die with the
  /// blocks they stamp.
  final Expando<DateTime> _stamped = Expando<DateTime>('chat-block-stamp');

  /// Gutter width: `HH:mm:ss ` — fixed, so stamps column-align across rows.
  static const int stampWidth = 9;

  @override
  List<RenderLine> render(ChatBlock value, RenderContext context) {
    final stamp = _format(_stamped[value] ??= _now());

    // Degrade to the plain look when the stamp would leave no room for
    // content — an overflow row is worse than a missing timestamp.
    if (context.width <= stampWidth + 2) {
      return const ChatRenderer().render(value, context);
    }

    // Lay the block out in the columns left of the gutter, then prepend the
    // stamp to the FIRST non-blank line only: a message spanning several
    // visual rows (explicit newlines or soft wrap) is one event — stamping
    // every row both doubled the noise and misread continuation lines as
    // separate messages. Blank separators stay blank either way, matching the
    // transcript's rule.
    final inner = RenderContext(
      width: context.width - stampWidth,
      theme: context.theme,
      animationFrame: context.animationFrame,
    );
    final out = <RenderLine>[];
    var stamped = false;
    for (final line in const ChatRenderer().render(value, inner)) {
      if (line.isBlank || stamped) {
        out.add(line);
      } else {
        stamped = true;
        out.add(
          RenderLine(
            bar: line.bar,
            align: line.align,
            animated: line.animated,
            runs: [RenderRun(stamp, context.theme.chat.dim), ...line.runs],
          ),
        );
      }
    }
    return out;
  }

  static String _format(DateTime at) =>
      '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)} ';

  static String _two(int v) => v.toString().padLeft(2, '0');
}
