/// One tool invocation as a chip: the [ToolUse], its [ToolResult] when it has
/// arrived, and the single chip line they render to.
///
/// The chip *state* is `tina_console`'s [ToolChip] (name, id, running /
/// success / error, output buffer) — this file adds no state of its own: it
/// builds chips from `tina_core` values, drives their lifecycle, and renders
/// from `chip.state`. Pure: no screen, no region, no I/O.
library;

import 'dart:convert';

import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';

/// Renders a [ToolUse] (plus its [ToolResult], when known) as chip rows.
///
/// The summary line is `⏺ name key: value, key: value` — the marker colored
/// from the [ToolChip.state] the brief's chip carries (dim while running,
/// green on success, red on error), arguments dim. Arguments are truncated
/// to the row width: a chip is a label for a call, not a transcript of it.
class ToolChipView {
  const ToolChipView._();

  /// The chip's state holder, as `tina_console` models it. Starts
  /// [ToolChipState.running]; a call whose arguments did not parse carries
  /// the parse error as its initial output.
  static ToolChip chip(ToolUse call) {
    final chip = ToolChip(toolName: call.name, toolId: call.id);
    final note = call.argumentsParseError;
    if (note != null) chip.outputBuffer.write(note);
    return chip;
  }

  /// Records [result] onto [chip]: state success/error, output appended.
  static void complete(ToolChip chip, ToolResult result) {
    chip.state = result.isError ? ToolChipState.error : ToolChipState.success;
    if (chip.outputBuffer.isNotEmpty) chip.outputBuffer.write('\n');
    chip.outputBuffer.write(result.content);
  }

  /// The one-line summary: tool name, then a compact argument rendering
  /// (or the parse-error note for a call whose arguments were not JSON).
  static String summary(ToolUse call) {
    final args = call.argumentsParseError ?? _inlineArgs(call.input);
    if (args.isEmpty) return call.name;
    return '${call.name} $args';
  }

  /// Chip rows for a call and its (possibly still absent) result.
  ///
  /// Internally builds the [ToolChip], applies the result through
  /// [complete], and colors from the resulting `chip.state` — `null` state
  /// means still running. When output exists, its first line follows as a
  /// dim `↳` row.
  static List<RenderLine> rows(
    ToolUse call,
    ToolResult? result, {
    required int width,
    Theme theme = const Theme.defaults(),
  }) {
    final chat = theme.chat;
    final chip = chipOf(call, result);
    final color = switch (chip.state) {
      ToolChipState.running => chat.dim,
      ToolChipState.success => chat.green,
      ToolChipState.error => chat.red,
    };
    final argText = call.argumentsParseError ?? _inlineArgs(call.input);
    final prefix = '⏺ ${call.name}';
    return [
      RenderLine(runs: [
        RenderRun(prefix, color),
        if (argText.isNotEmpty)
          RenderRun(
            ' ${_clip(argText, width - visibleWidth(prefix) - 1)}',
            chat.dim,
          ),
      ]),
      if (chip.outputBuffer.isNotEmpty)
        RenderLine(runs: [
          RenderRun(
            '  ↳ ${_clip(
              chip.outputBuffer.toString().trim().split('\n').first,
              width - 4,
            )}',
            chat.dim,
          ),
        ]),
    ];
  }

  /// A chip for [call] with [result] already applied.
  static ToolChip chipOf(ToolUse call, ToolResult? result) {
    final c = chip(call);
    if (result != null) complete(c, result);
    return c;
  }

  /// Compact `key: value` rendering; JSON-encoded values stay copy-pasteable
  /// and unambiguous about where each argument ends.
  static String _inlineArgs(Map<String, dynamic> input) {
    if (input.isEmpty) return '';
    return input.entries
        .map((e) => '${e.key}: ${jsonEncode(e.value)}')
        .join(', ');
  }

  /// Hard truncate to [width] visible columns with an ellipsis. A chip never
  /// wraps: it names a call, it does not transcribe it.
  static String _clip(String text, int width) {
    if (width <= 0) return '';
    if (visibleWidth(text) <= width) return text;
    var w = 0;
    var i = 0;
    while (i < text.length) {
      final size = runeSizeAt(text, i);
      final cw = runeWidth(codePointAt(text, i));
      if (w + cw > width - 1) break;
      w += cw;
      i += size;
    }
    return '${text.substring(0, i)}…';
  }
}
