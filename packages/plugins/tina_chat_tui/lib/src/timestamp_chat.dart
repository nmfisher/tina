import 'package:tina_console/tina_console.dart';
import 'chat_renderer.dart';
import 'chat_transcript.dart';

class TimestampChatRenderer extends Renderer<ChatBlock> {
  TimestampChatRenderer({required DateTime Function() now}) : _now = now;

  final DateTime Function() _now;

  /// First-render time per block instance. Weak keys: entries die with the
  /// blocks they stamp.
  final Expando<DateTime> _stamped = Expando<DateTime>('chat-block-stamp');

  void stamp(ChatBlock block, DateTime at) => _stamped[block] = at;

  /// Gutter width: `HH:mm ` — fixed, so stamps column-align across rows.
  static const int stampWidth = 6;

  @override
  List<RenderLine> render(ChatBlock value, RenderContext context) {
    final stamp = _format(_stamped[value] ??= _now());

    // Degrade to the plain look when the stamp would leave no room for
    // content — an overflow row is worse than a missing timestamp.
    if (context.width <= stampWidth + 2) {
      return const ChatRenderer().render(value, context);
    }

    // Reserve the same gutter on every content row. Only the first
    // nonblank row carries a timestamp; continuations keep its indentation.
    // Blank separators stay blank.
    final inner = RenderContext(
      width: context.width - stampWidth,
      theme: context.theme,
      animationFrame: context.animationFrame,
    );
    final out = <RenderLine>[];
    var stamped = false;
    for (final line in const ChatRenderer().render(value, inner)) {
      if (line.isBlank) {
        out.add(line);
      } else {
        final gutter = stamped ? ' ' * stampWidth : stamp;
        stamped = true;
        out.add(
          RenderLine(
            bar: line.bar,
            align: line.align,
            animated: line.animated,
            runs: [RenderRun(gutter, context.theme.chat.dim), ...line.runs],
          ),
        );
      }
    }
    return out;
  }

  static String _format(DateTime at) => '${_two(at.hour)}:${_two(at.minute)} ';

  static String _two(int v) => v.toString().padLeft(2, '0');
}
