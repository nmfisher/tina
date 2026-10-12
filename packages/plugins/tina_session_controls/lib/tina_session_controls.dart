export 'settings.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// One snapshot for model completion, listing and the interactive picker.
final class ModelCatalog {
  const ModelCatalog({
    this.models = const [],
    this.providerNames = const {},
    this.modelNames = const {},
  });
  final List<String> models;
  final Map<String, String> providerNames;
  final Map<String, String> modelNames;
}

/// Conversation controls with an optional interactive model picker.
final class SessionControlsPlugin extends AgentPlugin {
  SessionControlsPlugin({
    required this.terminal,
    required this.currentModel,
    required this.switchModel,
    required this.modelCatalog,
  });
  final Terminal terminal;
  final String Function() currentModel;
  final void Function(String) switchModel;
  // Read at use, including when this plugin is enabled after a settings save.
  final ModelCatalog Function() modelCatalog;
  AgentLoop? _loop;
  bool _closed = false;
  late final observation = SessionControlsObservation._(this);
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
          modelCatalog().models.where((m) => m.startsWith(prefix)).toList(),
      handler: (argument) async {
        if (_closed) return;
        var model = argument.trim();
        if (model.isEmpty) {
          terminal.writeln('Current model: ${currentModel()}');
          for (final item in modelCatalog().models) terminal.writeln(item);
          return;
        }
        try {
          switchModel(model);
          _recentModels.remove(currentModel());
          _recentModels.insert(0, currentModel());
          if (_recentModels.length > 10) _recentModels.removeLast();
          terminal.writeln('Model: ${currentModel()}');
        } catch (error) {
          terminal.writeln('Could not switch model: $error');
        }
      },
    ),
    Command(
      name: 'clear',
      description: 'clear conversation context and display',
      handler: (_) {
        if (_closed) return;
        _loop?.clearHistory();
        terminal.writeln('Conversation cleared.');
      },
    ),
  ];
  final _recentModels = <String>[];

  @override
  void closeSession() {
    _closed = true;
    _loop = null;
  }
}

/// Narrow model-picker operations. The view cannot clear history or access
/// the loop; command dispatch remains with the runtime plugin.
final class SessionControlsObservation {
  SessionControlsObservation._(
    this._plugin, [
    this._access = const ClientAccess(),
  ]);
  final SessionControlsPlugin _plugin;
  final ClientAccess _access;
  bool get canControl => _access.canControl;
  SessionControlsObservation forClient(ClientAccess access) =>
      SessionControlsObservation._(_plugin, _access.restrict(access));
  String get currentModel => _plugin.currentModel();
  ModelCatalog get catalog {
    final value = _plugin.modelCatalog();
    return ModelCatalog(
      models: List.unmodifiable(value.models),
      providerNames: Map.unmodifiable(value.providerNames),
      modelNames: Map.unmodifiable(value.modelNames),
    );
  }

  List<String> get recentModels => List.unmodifiable(_plugin._recentModels);
  Future<void> select(String model) async {
    _access.requireControl();
    await _plugin.commands.first.handler(model);
  }
}
