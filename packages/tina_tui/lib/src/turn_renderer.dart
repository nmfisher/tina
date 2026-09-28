import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// Paints transient deltas, then reconciles against the authoritative log.
/// Providers that only emit a completion still display their full reply.
final class TurnRenderer {
  TurnRenderer(this.screen);
  final Screen screen;
  String _streamed = '';
  bool _lineOpen = false;

  String? _activeTool;
  int _outputCharacters = 0;

  /// Generic execution observations; no dependency on any concrete tool plugin.
  void tool(ToolActivity event) {
    switch (event) {
      case ToolStarted(:final call):
        _activeTool = call.id;
        _outputCharacters = 0;
        line('tool: ${_plain(call.name)} — running');
      case ToolOutput(:final call, :final text):
        if (_activeTool != call.id || _outputCharacters >= 65536) return;
        final clean = _plain(text);
        final remaining = 65536 - _outputCharacters;
        final visible =
            clean.length > remaining ? clean.substring(0, remaining) : clean;
        _outputCharacters += visible.length;
        screen.frame(() => screen.chat.write(visible));
        _lineOpen = !visible.endsWith('\n');
        if (_outputCharacters >= 65536) line('[further live output hidden]');
      case ToolFinished(:final call, :final result):
        line(
            'tool: ${_plain(call.name)} — ${result.isError ? 'error' : 'done'}');
        final preview = _plain(result.content)
            .split('\n')
            .take(_outputCharacters == 0 ? 3 : 1)
            .join('\n');
        if (preview.isNotEmpty)
          line(
              preview.length > 500 ? '${preview.substring(0, 500)}…' : preview);
        _activeTool = null;
    }
  }

  // Subprocesses can emit terminal control sequences. Render them as text.
  static String _plain(String text) => text
      .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '');

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
