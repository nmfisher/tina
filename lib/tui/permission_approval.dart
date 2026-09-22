import 'dart:math' as math;

import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../chat/markdown_renderer.dart';
import '../frontend/renderers.dart';
import 'approval_card.dart';
import 'prompts.dart';

/// Shared inline approval for conversations and workflow nodes. The frame uses
/// the same input-anchored region as questions; it is never a centered popup.
Future<PermissionResponse> runPermissionApproval({
  required Screen screen,
  required LineEditor editor,
  required PermissionPrompt prompt,
  required void Function(String text) write,
  Renderers renderers = const Renderers(),
  PermissionPolicy? policy,
  String? sandboxWarning,
}) async {
  final cancel = Future.any<void>([
    editor.inputCancelled,
    if (prompt.cancelSignal != null) prompt.cancelSignal!,
  ]);
  final preview = await previewToolCall(
    prompt.toolName,
    prompt.input,
    preparedEdit: prompt.preparedEdit,
  );
  final session = Prompts.of(editor).open(cancelSignal: cancel);
  final overlay = OverlayRegion(screen, Rect.empty);
  final choices = prompt.choices;
  var selected = 0;
  var offset = 0;
  var pageSize = 1;
  var details = false;
  var acknowledged = false;
  ApprovalChoice? answer;

  ApprovalCard card() => ApprovalCard(
    prompt: prompt,
    preview: preview,
    mode: policy == null ? null : permissionModeChip(policy.mode),
    sandboxWarning: sandboxWarning,
    details: details,
  );

  String style(String text, String? code) =>
      code != null && screen.ansi.useColor ? screen.colorize(code, text) : text;

  List<String> body(int width) => renderers
      .render(
        card(),
        RenderContext(width: width, theme: screen.theme),
        fallback: const ApprovalRenderer(),
      )
      .map((line) {
        final rendered = serializeLine(
          line,
          MarkdownStyle.fromChatTheme(screen.theme.chat),
          styled: screen.ansi.useColor,
        );
        return style(rendered.text, rendered.bar);
      })
      .toList();

  void paint() {
    if (!session.isActive) return;
    final input = screen.input.bounds;
    final height = input.row - screen.layout.chat.row;
    if (height <= 0 || input.width < 4) return;
    final width = input.width - 2;
    final content = body(width);
    final actions = <String>[];
    for (var i = 0; i < choices.length; i++) {
      final label =
          '${i == selected ? '❯' : ' '} [${choices[i].key}] ${approvalChoiceLabel(choices[i])}';
      for (final row in approvalWrap(label, width)) {
        actions.add(
          style(
            row,
            i == selected
                ? screen.theme.completion.selected
                : screen.theme.completion.dim,
          ),
        );
      }
    }
    // Small panels retain the selected answer and navigation rather than
    // hiding the focused choice behind the preview.
    if (actions.length > height - 5) {
      actions.clear();
      actions.addAll(
        approvalWrap(
          '❯ ${selected + 1}/${choices.length} [${choices[selected].key}] ${approvalChoiceLabel(choices[selected])}',
          width,
        ).map((row) => style(row, screen.theme.completion.selected)),
      );
    }
    pageSize = math.max(1, height - actions.length - 5);
    offset = offset.clamp(0, math.max(0, content.length - pageSize));
    final end = math.min(content.length, offset + pageSize);
    final count = content.length > pageSize
        ? 'Preview ${offset + 1}–$end/${content.length} · PgUp/PgDn or wheel'
        : '';
    final lines = [
      '┌ ${card().title} · ${prompt.outsideSandbox ? 'outside sandbox · ' : ''}awaiting approval',
      for (final row in content.skip(offset).take(pageSize)) '│ $row',
      '│ ${style(count, screen.theme.completion.dim)}',
      for (final row in actions) '│ $row',
      '│ ↑↓ choose · Enter confirm · Tab ${details ? 'less' : 'details'} · Esc deny',
      '└',
    ];
    overlay.update(
      bounds: Rect(
        row: math.max(screen.layout.chat.row, input.row - lines.length),
        col: input.col,
        width: input.width,
        height: math.min(height, lines.length),
      ),
      lines: lines,
    );
    screen.input.render(
      prompt: '❯ ',
      buffer: 'Approve ${prompt.toolName}?',
      cursor: 0,
    );
  }

  session.attach(paint: paint, hide: overlay.hide);
  try {
    paint();
    while (true) {
      final event = await session.read();
      if (event is EscapeKey ||
          event is ControlKey && event.code == ControlCode.ctrlC)
        break;
      if (event is CharInput) {
        answer = prompt.choiceForKey(event.text);
        if (answer != null) break;
      }
      if (event is ControlKey && event.code == ControlCode.enter) {
        answer = choices[selected];
        break;
      }
      if (event is ArrowKey) {
        switch (event.direction) {
          case ArrowDirection.up:
            selected = math.max(0, selected - 1);
          case ArrowDirection.down:
            selected = math.min(choices.length - 1, selected + 1);
          case ArrowDirection.pageUp:
            offset -= pageSize;
          case ArrowDirection.pageDown:
            offset += pageSize;
          default:
            break;
        }
      } else if (event is ScrollEvent) {
        offset += event.up ? -3 : 3;
      } else if (event is ControlKey && event.code == ControlCode.tab) {
        details = !details;
        offset = details ? 1 << 30 : 0;
      } else if (event is ControlKey && event.code == ControlCode.backtab) {
        editor.onBackTab?.call();
      } else if (!acknowledged) {
        acknowledged = true;
        write('$ignoredKeyAck\n');
      }
      paint();
    }
  } finally {
    overlay.hide();
    overlay.dispose();
    session.close();
    if (Prompts.of(editor).active != null) {
      // The restored prompt owns the input row.
    } else if (editor.isEditing) {
      editor.refresh();
    } else {
      screen.input.erase();
    }
  }
  // Store one settled card in scrollback. Repainting/scrolling while awaiting
  // an answer never appends copies of the prompt to the conversation.
  final result = answer == null ? 'cancelled' : approvalChoiceLabel(answer);
  write(
    [
      '┌ ${card().title} · $result',
      for (final row in body(math.max(1, screen.input.bounds.width - 2)))
        '│ $row',
      '└\n',
    ].join('\n'),
  );
  return answer?.response ?? PermissionResponse.denyOnce;
}
