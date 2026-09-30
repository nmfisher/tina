import 'package:tina_console/tina_console.dart';
import 'chat_renderer.dart';
import 'chat_transcript.dart';

class TimestampChatRenderer extends Renderer<ChatBlock> {
  TimestampChatRenderer({required DateTime Function() now}) : _now = now;

  final DateTime Function() _now;

  /// First-render time per block instance. Weak keys: entries die with the
  /// blocks they stamp.
  final Expando<ChatBlock> _previous =
      Expando<ChatBlock>('previous-chat-block');

  void follow(ChatBlock block, ChatBlock? previous) =>
      _previous[block] = previous;

  /// Recompute adjacency after transcript blocks are added or removed.
  void group(Iterable<ChatBlock> blocks) {
    ChatBlock? previous;
    for (final block in blocks) {
      _previous[block] = previous;
      previous = block;
    }
  }

  final Expando<DateTime> _stamped = Expando<DateTime>('chat-block-stamp');

  void stamp(ChatBlock block, DateTime at) => _stamped[block] = at;

  /// Gutter width: `HH:mm ` — fixed, so stamps column-align across rows.
  static const int stampWidth = 6;

  @override
  List<RenderLine> render(ChatBlock value, RenderContext context) {
    final at = _stamped[value] ??= _now();
    final previous = _previous[value];
    final previousAt = previous == null ? null : _stamped[previous];
    final showStamp = previous == null ||
        previous.speaker != value.speaker ||
        previousAt == null ||
        _minute(previousAt) != _minute(at);
    final stamp = showStamp ? _format(at) : ' ' * stampWidth;

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

  static DateTime _minute(DateTime at) {
    final local = at.toLocal();
    return DateTime(
        local.year, local.month, local.day, local.hour, local.minute);
  }

  static String _format(DateTime at) => '${_two(at.hour)}:${_two(at.minute)} ';

  static String _two(int v) => v.toString().padLeft(2, '0');
}
