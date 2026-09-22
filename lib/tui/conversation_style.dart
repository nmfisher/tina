import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../frontend/renderers.dart';

/// Layout contribution, separate from the renderer's text and colors.
class ConversationStyle {
  final bool border;
  const ConversationStyle({this.border = false});

  static ConversationStyle resolve(PluginScope? scope) {
    for (var current = scope; current != null; current = current.parent) {
      if (!current.isAdmitting) continue;
      for (final entry in current.contributions) {
        if (entry.contribution case final ConversationStyle style) return style;
      }
    }
    return const ConversationStyle();
  }
}

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
  Screen screen,
  PluginScope? scope, {
  required int width,
  int animationFrame = 0,
}) {
  final budget = width ~/ 2;
  if (budget <= 0) return '';
  final lines = Renderers(scope).render(
    value,
    RenderContext(
      width: budget,
      theme: screen.theme,
      animationFrame: animationFrame,
    ),
    fallback: const PromptRenderer(),
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
