/// Live transcript: a [StreamView] accumulates `tina_core` stream events and
/// renders the same rows [ChatView] shows for the settled message.
///
/// The brief's contract: [apply] handles `TextDelta`, `ReasoningDelta`,
/// `ToolCallStart` and `MessageComplete`; `rows` exposes the accumulated
/// state. It is deliberately shaped so a provider decorator wrapping
/// `LlmProvider` can feed it — a `StreamEvent` consumer with no terminal.
library;

import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';

import 'chat_view.dart';

/// Accumulated state of one streaming assistant turn.
///
/// Apply events as they arrive; read [rows] whenever the host repaints.
/// `TextDelta`/`ReasoningDelta` mutate the trailing accumulation; a chip is
/// opened by `ToolCallStart`; `MessageComplete` resets the view to the
/// completed message's rows (streamed text and blocks can differ — completion
/// wins). Late `TextDelta` after completion starts a fresh accumulation.
class StreamView {
  final StringBuffer _text = StringBuffer();
  final StringBuffer _reasoning = StringBuffer();
  final List<ToolUse> _calls = [];
  final List<RenderLine> _completed = [];

  /// Column budget the rows are laid out for. Fixed at construction so
  /// [rows] stays a getter; hosts rebuild on resize.
  final int width;

  StreamView({this.width = 80});

  bool _done = false;

  /// Ingest one event.
  void apply(StreamEvent event) {
    switch (event) {
      case TextDelta(:final text):
        if (_done) {
          // A delta after completion is the next turn's first token.
          _done = false;
          _completed.clear();
        }
        _text.write(text);
      case ReasoningDelta(:final text):
        if (_done) {
          _done = false;
          _completed.clear();
        }
        _reasoning.write(text);
      case ReasoningEnd():
        break; // one reasoning block per attempt; accumulation continues
      case StreamNotice(:final text):
        if (_done) return;
        _reasoning.write(text);
      case ToolCallStart(:final id, :final name):
        if (_done) {
          _done = false;
          _completed.clear();
        }
        _calls.add(ToolUse(id: id, name: name, input: const {}));
      case MessageComplete(:final content):
        _text.clear();
        _reasoning.clear();
        _calls.clear();
        _completed
          ..clear()
          ..addAll(const ChatView().render(
            Message(role: Role.assistant, content: List.of(content)),
            width: width,
          ));
        _done = true;
      case StreamError():
        break; // policy concern; the loop decides, the view shows nothing
    }
  }

  /// The rows for the turn so far: reasoning, streamed text, chip rows per
  /// open tool call. Completed turns show the completion's rows.
  List<RenderLine> get rows => [
        if (_completed.isNotEmpty)
          ..._completed
        else ...[
          if (_reasoning.isNotEmpty)
            RenderLine(runs: [
              RenderRun('· ${_clip(_reasoning.toString(), width - 4)}', '2'),
            ]),
          if (_text.isNotEmpty)
            RenderLine(runs: [RenderRun(_text.toString(), null)]),
          for (final call in _calls) ...toolChipRows(call, null, width: width),
        ],
      ];

  /// True once [MessageComplete] was applied.
  bool get isComplete => _done;
}

String _clip(String text, int width) {
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
