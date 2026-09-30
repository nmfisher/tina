import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// Conversation controls with an optional interactive model picker.
final class SessionControlsPlugin extends AgentPlugin
    implements ConsoleContribution {
  SessionControlsPlugin(
      {required this.terminal,
      required this.currentModel,
      required this.switchModel,
      required this.models});
  final Terminal terminal;
  final String Function() currentModel;
  final void Function(String) switchModel;
  final List<String> models;
  AgentLoop? _loop;
  ConsoleContext? _console;
  void Function()? _paint;
  @override
  String get id => 'tina/session-controls';
  @override
  void mountOn(AgentLoop loop) => _loop = loop;
  @override
  List<Command> get commands => [
        Command(
            name: 'model',
            description: 'pick or change this conversation model',
            complete: (prefix) =>
                models.where((m) => m.startsWith(prefix)).toList(),
            handler: (argument) async {
              var model = argument.trim();
              if (model.isEmpty) {
                final console = _console;
                if (console == null) {
                  terminal.writeln('Current model: ${currentModel()}');
                  for (final item in models) {
                    terminal.writeln(item);
                  }
                  return;
                }
                model = await console.interact(() => _pick(console)) ?? '';
                if (model.isEmpty) return;
              }
              try {
                switchModel(model);
                terminal.writeln('Model: ${currentModel()}');
                _console?.refreshInput();
              } catch (error) {
                terminal.writeln('Could not switch model: $error');
              }
            }),
        Command(
            name: 'clear',
            description: 'clear conversation context and display',
            handler: (_) {
              _loop?.clearHistory();
              terminal.writeln('Conversation cleared.');
            }),
      ];
  Future<String?> _pick(ConsoleContext console) async {
    final overlay = OverlayRegion(console.screen, Rect.empty);
    var query = '';
    var selected = models.indexOf(currentModel()).clamp(0, models.length);
    try {
      while (true) {
        final matches = models
            .where((m) => m.toLowerCase().contains(query.toLowerCase()))
            .toList();
        _paint = () {
          final area = dialogArea(console.screen.layout);
          final room = (area.height - 3).clamp(1, 10000);
          if (matches.isNotEmpty)
            selected = selected.clamp(0, matches.length - 1);
          final start = (selected - room + 1).clamp(0, matches.length);
          overlay.update(
              bounds: area,
              lines: [
                'Model · ${currentModel()}',
                'Find: $query',
                if (matches.isEmpty) 'No matching models',
                for (var i = start; i < matches.length && i < start + room; i++)
                  '${i == selected ? '›' : ' '} ${matches[i]}',
                '↑↓ choose · type to filter · Enter select · Esc cancel',
              ]
                  .take(area.height)
                  .map((line) => clipDialogText(line, area.width))
                  .toList());
        };
        _paint!();
        final event = await console.input.readKey(acceptPaste: true);
        switch (event) {
          case EscapeKey():
          case ControlKey(code: ControlCode.ctrlC):
            return null;
          case ControlKey(code: ControlCode.enter):
            if (matches.isNotEmpty) return matches[selected];
          case ArrowKey(direction: ArrowDirection.up):
            selected = (selected - 1).clamp(0, matches.length);
          case ArrowKey(direction: ArrowDirection.down):
            selected++;
          case ControlKey(code: ControlCode.backspace):
            if (query.isNotEmpty) {
              query = query.substring(0, query.length - 1);
              selected = 0;
            }
          case CharInput(:final text):
          case PasteInput(:final text):
            query += text.replaceAll(RegExp(r'[\r\n]'), '');
            selected = 0;
          default:
            break;
        }
      }
    } finally {
      _paint = null;
      overlay.hide();
      console.chat.repaint();
      console.refreshInput();
    }
  }

  @override
  void attachConsole(ConsoleContext context) => _console = context;
  @override
  void detachConsole() => _console = null;
  @override
  void repaintConsole() => _paint?.call();
  @override
  void closeSession() {
    _loop = null;
    detachConsole();
  }
}
