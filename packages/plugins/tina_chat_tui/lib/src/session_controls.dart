import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// One snapshot for model completion, listing and the interactive picker.
final class ModelCatalog {
  const ModelCatalog(
      {this.models = const [],
      this.providerNames = const {},
      this.modelNames = const {}});
  final List<String> models;
  final Map<String, String> providerNames;
  final Map<String, String> modelNames;
}

/// Conversation controls with an optional interactive model picker.
final class SessionControlsPlugin extends AgentPlugin
    implements ConsoleContribution {
  SessionControlsPlugin(
      {required this.terminal,
      required this.currentModel,
      required this.switchModel,
      required this.modelCatalog});
  final Terminal terminal;
  final String Function() currentModel;
  final void Function(String) switchModel;
  // Read at use, including when this plugin is enabled after a settings save.
  final ModelCatalog Function() modelCatalog;
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
            complete: (prefix) => modelCatalog()
                .models
                .where((m) => m.startsWith(prefix))
                .toList(),
            handler: (argument) async {
              var model = argument.trim();
              if (model.isEmpty) {
                final console = _console;
                if (console == null) {
                  terminal.writeln('Current model: ${currentModel()}');
                  for (final item in modelCatalog().models) {
                    terminal.writeln(item);
                  }
                  return;
                }
                model = await console.interact(() => _pick(console)) ?? '';
                if (model.isEmpty) return;
              }
              try {
                switchModel(model);
                _recentModels.remove(currentModel());
                _recentModels.insert(0, currentModel());
                if (_recentModels.length > 10) _recentModels.removeLast();
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
  final _recentModels = <String>[];

  Future<String?> _pick(ConsoleContext console) async {
    final catalog = modelCatalog();
    final picker = ModelSearchPicker(
      screen: console.screen,
      modelRefs: catalog.models,
      providerNames: catalog.providerNames,
      modelNames: catalog.modelNames,
      title: 'Switch model',
      recentRefs: [
        _recentModels,
        [currentModel()]
      ].expand((refs) => refs).toList(),
      readEvent: () => console.input.readKey(acceptPaste: true),
      accent: console.screen.theme.border.focus,
    );
    _paint = picker.repaint;
    try {
      return await picker.run();
    } finally {
      _paint = null;
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
