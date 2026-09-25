import 'dart:async';

import 'package:tina_console/tina_console.dart';

import '../chat/chat_agent_sink.dart';
import 'spawn_overlay.dart';

/// The transcript cursor: a keyboard mode for *reading* a conversation.
///
/// The chat is a transcript of blocks, and two kinds of block hide their
/// contents behind a one-line header — a tool call shows its outcome but not its
/// output, and a reasoning block shows a character count but not the thought.
/// Ctrl+B opens this mode to walk them:
///
///   ↑ / ↓      step between the blocks that can fold
///   ⏎ / space  reveal the focused block, or collapse it again
///   PgUp/PgDn  scroll the transcript (the cursor stays where it is)
///   esc / ^C / ^B  leave
///
/// The focused block's header is tinted with the selection colour and scrolled
/// into view, so the cursor cannot walk off screen. Nothing here edits the
/// transcript: it moves a mark and toggles [ChatBlock.folded], and the sink
/// repaints.
///
/// [readEvent] is a test seam (an injected key source); production reads from
/// [editor].
Future<void> runTranscriptCursor({
  required LineEditor editor,
  required ScrollingTextRegion chat,
  required ChatAgentSink transcript,
  Future<InputEvent> Function()? readEvent,
}) async {
  // Foldable blocks can appear while the cursor is open (a turn is streaming),
  // so the list is recomputed on every key rather than captured.
  List<int> foldable() => transcript.foldableIndexes;

  var at = foldable().length - 1; // start on the newest
  if (at < 0) return;

  void paint() {
    final indexes = foldable();
    if (indexes.isEmpty) return;
    if (at >= indexes.length) at = indexes.length - 1;
    final index = indexes[at];
    transcript.highlightBlock(index);
    final row = transcript.rowOfBlock(index);
    if (row != null) chat.scrollRowIntoView(row);
  }

  paint();
  final read = readEvent ?? editor.captureKeyReader();
  final prev = modalTakeFocus(editor);
  try {
    while (true) {
      final event = await read();

      if (event is EscapeKey) break;
      if (event is ControlKey &&
          (event.code == ControlCode.ctrlC ||
              event.code == ControlCode.ctrlB)) {
        break;
      }

      var handled = false;
      if (event is ArrowKey) {
        switch (event.direction) {
          case ArrowDirection.up:
            if (at > 0) {
              at--;
              handled = true;
            }
          case ArrowDirection.down:
            if (at < foldable().length - 1) {
              at++;
              handled = true;
            }
          case ArrowDirection.pageUp:
            chat.scrollBy(-chat.usableHeight);
          case ArrowDirection.pageDown:
            chat.scrollBy(chat.usableHeight);
          case ArrowDirection.left:
          case ArrowDirection.right:
            break; // horizontal arrows have nothing to do here
        }
      } else if ((event is ControlKey && event.code == ControlCode.enter) ||
          (event is CharInput && event.text == ' ')) {
        final indexes = foldable();
        if (at < indexes.length) {
          // Repaint without the mark first: the sink repaints the block's rows
          // and the mark would otherwise be applied to the new layout too.
          transcript.highlightBlock(null);
          transcript.toggleFold(indexes[at]);
          handled = true;
        }
      }

      // Repaint either way: PgUp/PgDn and a fold both move things under the
      // mark, and the highlight and the viewport must not disagree.
      paint();
      if (handled) {
        final indexes = foldable();
        // A reveal grows the block downward, so scrolling its *header* into
        // view would leave the content below the window. Answer the question
        // the keystroke asked: show what is inside it.
        final row = indexes.isEmpty || at >= indexes.length
            ? null
            : (transcript.blocks[indexes[at]].folded
                  ? transcript.rowOfBlock(indexes[at])
                  : transcript.endRowOfBlock(indexes[at]));
        if (row != null) chat.scrollRowIntoView(row);
      }
    }
  } finally {
    transcript.highlightBlock(null);
    modalRestoreFocus(editor, prev);
  }
}
