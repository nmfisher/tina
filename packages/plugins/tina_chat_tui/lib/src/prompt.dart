import 'package:tina_console/tina_console.dart';

/// Live presentation data. Never added to the message sent to the agent.
class ConversationPrompt {
  final String conversationId;
  final String model;
  final bool busy;
  final bool focused;
  final bool highlighted;
  final int newLines;

  const ConversationPrompt({
    required this.conversationId,
    required this.model,
    this.busy = false,
    this.focused = false,
    this.highlighted = false,
    this.newLines = 0,
  });
}

class PromptRenderer extends Renderer<ConversationPrompt> {
  const PromptRenderer();
  static const _frames = ['|', '/', '-', '\\'];

  @override
  List<RenderLine> render(ConversationPrompt value, RenderContext context) {
    var model = value.model.split('/').last;
    final busy = value.busy ? ' ${_frames[context.animationFrame % 4]}' : '';
    final badge = value.newLines > 0 ? ' ↓ ${value.newLines} new' : '';
    final suffix = '$busy$badge > ';
    final available = context.width - plainWidth(suffix);
    if (available <= 0) {
      return [
        const RenderLine(runs: [RenderRun('> ', null)]),
      ];
    }
    if (plainWidth(model) > available) {
      final short = StringBuffer();
      var left = available - 1;
      for (final rune in model.runes) {
        if (runeWidth(rune) > left) break;
        short.writeCharCode(rune);
        left -= runeWidth(rune);
      }
      model = '$short…';
    }
    final color = value.highlighted
        ? context.theme.border.selection
        : value.focused
            ? context.theme.border.focus
            : context.theme.chat.dim;
    return [
      RenderLine(runs: [RenderRun('$model$suffix', color)]),
    ];
  }
}

/// The prompt is one row. Leave at least half the input width for typing,
/// strip control characters and apply styles through the screen API.
String renderConversationPrompt(
  ConversationPrompt value,
  Screen screen, {
  required int width,
  int animationFrame = 0,
}) {
  final budget = width ~/ 2;
  if (budget <= 0) return '';
  final lines = const PromptRenderer().render(
    value,
    RenderContext(
      width: budget,
      theme: screen.theme,
      animationFrame: animationFrame,
    ),
  );
  if (lines.isEmpty) return '';
  var remaining = budget;
  final result = StringBuffer();
  for (final run in lines.first.runs) {
    final text = StringBuffer();
    for (final rune in run.text.runes) {
      if (rune < 32 || (rune >= 127 && rune < 160)) continue;
      final cells = runeWidth(rune);
      if (cells > remaining) break;
      text.writeCharCode(rune);
      remaining -= cells;
    }
    result.write(run.code == null ? text : screen.colorize(run.code!, '$text'));
    if (remaining == 0) break;
  }
  return result.toString();
}
