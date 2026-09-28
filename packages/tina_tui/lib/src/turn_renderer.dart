import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// Paints transient deltas, then reconciles against the authoritative log.
/// Providers that only emit a completion still display their full reply.
final class TurnRenderer {
  TurnRenderer(this.screen);
  final Screen screen;
  String _streamed = '';
  bool _lineOpen = false;

  void watch(WatchEvent event) {
    if (event is SawText && event.text.isNotEmpty) {
      screen.frame(() {
        if (!_lineOpen) screen.chat.write('tina: ');
        _lineOpen = true;
        _streamed += event.text;
        screen.chat.write(event.text);
      });
    } else if (event is SawNotice) {
      line(event.text);
    }
  }

  void entry(SessionEntry entry, LogEvent event) {
    if (event != LogEvent.appended) return;
    if (entry is InputRecordedEntry) {
      line('you: ${entry.text}');
    } else if (entry is MessageAppendedEntry &&
        entry.message.role == Role.assistant) {
      final text = entry.message.content
          .whereType<TextBlock>()
          .map((block) => block.text)
          .join();
      screen.frame(() {
        if (_streamed.isNotEmpty && text.startsWith(_streamed)) {
          screen.chat.write(text.substring(_streamed.length));
        } else if (text.isNotEmpty) {
          finishLine();
          screen.chat.write('tina: $text');
          _lineOpen = true;
        }
        finishLine();
        _streamed = '';
      });
    } else if (entry is TurnEndedEntry) {
      finishLine();
      _streamed = '';
    }
  }

  void finishLine() {
    if (!_lineOpen) return;
    screen.frame(() => screen.chat.writeln());
    _lineOpen = false;
  }

  void line(String text) {
    finishLine();
    screen.frame(() => screen.chat.writeln(text));
  }
}
