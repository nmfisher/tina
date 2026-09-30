import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// Conversation controls with an optional interactive model picker.
final class SessionControlsPlugin extends AgentPlugin
    implements ConsoleContribution {
  SessionControlsPlugin(
      {required this.terminal,
      required this.currentModel,
      required this.switchModel,
      required this.models,
      this.providerNames = const {},
      this.modelNames = const {}});
  final Terminal terminal;
  final String Function() currentModel;
  final void Function(String) switchModel;
  final List<String> models;
  final Map<String, String> providerNames;
  final Map<String, String> modelNames;
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
    String providerOf(String ref) => ref.split('/').first;
    String providerLabel(String ref) {
      final id = providerOf(ref);
      final name = providerNames[id];
      return name == null || name == id ? id : '$name ($id)';
    }

    String modelLabel(String ref) {
      final slash = ref.indexOf('/');
      final id = slash < 0 ? ref : ref.substring(slash + 1);
      final name = modelNames[ref];
      return name == null || name == id ? id : '$name · $id';
    }

    try {
      while (true) {
        final matches = models
            .where((m) => '$m ${providerLabel(m)} ${modelLabel(m)}'
                .toLowerCase()
                .contains(query.toLowerCase()))
            .toList();
        _paint = () {
          final area = dialogArea(console.screen.layout);
          final room = (area.height - 3).clamp(1, 10000);
          if (matches.isNotEmpty)
            selected = selected.clamp(0, matches.length - 1);
          final rows = <String>[];
          final rowForModel = <int>[];
          String? previous;
          for (var i = 0; i < matches.length; i++) {
            final ref = matches[i];
            final provider = providerOf(ref);
            if (provider != previous) {
              rows.add(console.screen.colorize('cyan', providerLabel(ref)));
              previous = provider;
            }
            rowForModel.add(rows.length);
            rows.add('${i == selected ? '▸' : ' '} ${modelLabel(ref)}'
                '${ref == currentModel() ? ' (current)' : ''}');
          }
          var start = matches.isEmpty
              ? 0
              : (rowForModel[selected] - room + 1).clamp(0, rows.length);
          // Repeat the provider header when scrolling into its model group.
          if (start > 0 && matches.isNotEmpty && room > 1) {
            start = (rowForModel[selected] - room + 2).clamp(0, rows.length);
          }
          final visible = rows.skip(start).take(room).toList();
          if (start > 0 &&
              matches.isNotEmpty &&
              room > 1 &&
              rowForModel.contains(start)) {
            final index = rowForModel.indexOf(start);
            visible.insert(0,
                console.screen.colorize('cyan', providerLabel(matches[index])));
          }
          overlay.update(
              bounds: area,
              lines: [
                'Model · ${currentModel()}',
                'Find: $query',
                if (matches.isEmpty) 'No matching models',
                ...visible.take(room),
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
