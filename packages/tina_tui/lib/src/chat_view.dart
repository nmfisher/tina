/// A settled transcript [Message] rendered to chip rows.
///
/// Rows follow the current terminal idiom: user text bold, agent prose
/// default, reasoning and tool calls dim. The tool row itself comes from
/// [ToolChipView] — `tina_console`'s chip state, tina's rendering. Pure:
/// no screen, no region, no I/O.
library;

import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';

import 'tool_chip_view.dart';

/// Renders a [Message] (its blocks and reasoning) to rows.
class ChatView {
  const ChatView();

  /// Rows for one message at [width] columns under [theme].
  ///
  /// - Each [TextBlock] paragraph becomes one row, bold for user text.
  /// - Each [ToolUseBlock] becomes a chip row ([toolChipRows]); the matching
  ///   [ToolResultBlock] (by `tool_use_id`) colors the chip and supplies its
  ///   output line. Results with no call in this message are skipped.
  /// - [ReasoningBlock]s render dim, prefixed `· `.
  List<RenderLine> render(
    Message message, {
    required int width,
    Theme theme = const Theme.defaults(),
  }) {
    final chat = theme.chat;
    final rows = <RenderLine>[];

    for (final reason in message.reasoning) {
      for (final line in _wrap(reason.text, width)) {
        rows.add(RenderLine(runs: [RenderRun('· $line', chat.dim)]));
      }
    }

    final results = {
      for (final block in message.content)
        if (block is ToolResultBlock) block.toolUseId: block,
    };

    for (final block in message.content) {
      switch (block) {
        case TextBlock(:final text):
          final style = message.role == Role.user ? chat.userText : null;
          for (final line in _wrap(text, width)) {
            rows.add(RenderLine(runs: [RenderRun(line, style)]));
          }
        case ToolUseBlock():
          final call = ToolUse.fromBlock(block);
          final result = results[block.id];
          rows.addAll(toolChipRows(
            call,
            result == null
                ? null
                : ToolResult(result.content, isError: result.isError),
            width: width,
            theme: theme,
          ));
        case ToolResultBlock():
          break; // attached to its call above
      }
    }
    return rows;
  }
}

/// The one-line tool chip: `⏺ name {args}` colored by outcome, then the
/// result's first line dim when a result exists. Pure delegation to
/// [ToolChipView.rows] — the chip state lives in `tina_console`'s [ToolChip].
List<RenderLine> toolChipRows(
  ToolUse call,
  ToolResult? result, {
  required int width,
  Theme theme = const Theme.defaults(),
}) {
  return ToolChipView.rows(call, result, width: width, theme: theme);
}

/// Greedy word wrap on visible columns; long words are hard-split.
List<String> _wrap(String text, int width) {
  final effective = width < 1 ? 1 : width;
  final out = <String>[];
  for (final paragraph in text.split('\n')) {
    var line = StringBuffer();
    var used = 0;
    for (var word in paragraph.split(' ')) {
      while (visibleWidth(word) > effective) {
        if (used > 0) {
          out.add(line.toString());
          line = StringBuffer();
          used = 0;
        }
        var take = 0;
        var i = 0;
        while (i < word.length) {
          final size = runeSizeAt(word, i);
          final cw = runeWidth(codePointAt(word, i));
          if (take + cw > (effective == 1 ? 1 : effective - 1)) break;
          take += cw;
          i += size;
        }
        out.add(word.substring(0, i));
        word = word.substring(i);
      }
      final wordWidth = visibleWidth(word);
      if (used > 0 && used + 1 + wordWidth > effective) {
        out.add(line.toString());
        line = StringBuffer();
        used = 0;
      } else if (used > 0) {
        line.write(' ');
        used += 1;
      }
      line.write(word);
      used += wordWidth;
    }
    out.add(line.toString());
  }
  return out;
}
