import 'package:tina_console/tina_console.dart';

import 'chat_transcript.dart';

/// Default layout and row styles for all transcript block kinds.
class ChatRenderer extends Renderer<ChatBlock> {
  final ChatGutter? gutter;
  const ChatRenderer({this.gutter});

  @override
  List<RenderLine> render(ChatBlock value, RenderContext context) {
    final theme = context.theme.chat;
    final rowStyle = switch (value.kind) {
      ChatBlockKind.user => theme.userText,
      ChatBlockKind.prose => null,
      ChatBlockKind.reasoning || ChatBlockKind.toolCall => theme.dim,
      ChatBlockKind.notice => switch (value.notice) {
        'warn' => theme.yellow,
        'error' => theme.red,
        _ => theme.dim,
      },
    };
    return [
      for (final line in renderTranscript(
        [value],
        width: context.width,
        gutter: gutter,
      ))
        if (line.isBlank)
          line
        else
          RenderLine(bar: line.bar ?? rowStyle, runs: line.runs),
    ];
  }
}
