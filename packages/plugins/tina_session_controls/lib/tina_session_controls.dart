export 'settings.dart';
export 'observation.dart';
export 'operations.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'observation.dart';
import 'settings.dart';

/// Conversation controls with an optional interactive model picker.
final class SessionControlsPlugin extends AgentPlugin {
  SessionControlsPlugin({
    required this.terminal,
    required this.currentModel,
    required this.switchModel,
    required this.modelCatalog,
    this.currentReasoning,
    this.setReasoning,
    this.reasoningChoices,
  });
  final Terminal terminal;
  final String Function() currentModel;
  final void Function(String) switchModel;
  // Read at use, including when this plugin is enabled after a settings save.
  final ModelCatalog Function() modelCatalog;

  /// The conversation's effective reasoning effort, or null when the host
  /// has no settings stack (headless with no config). Null disables /reasoning.
  final String? Function()? currentReasoning;

  /// Persist a reasoning choice for this conversation. Throws on rejection;
  /// 'auto' removes the override. Null disables /reasoning.
  final void Function(String)? setReasoning;

  /// Effort words the current model accepts, for completion and validation.
  /// Null means every canonical word is offered.
  final List<String> Function()? reasoningChoices;
  AgentLoop? _loop;
  bool _closed = false;
  late final SessionControlsObservation observation =
      _SessionControlsObservation(this);
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
          selectModel(model);
          terminal.writeln('Model: ${currentModel()}');
        } catch (error) {
          terminal.writeln('Could not switch model: $error');
        }
      },
    ),
    Command(
      name: 'reasoning',
      description:
          'reasoning effort: ${reasoningEffortWords.join(', ')} (empty shows the current choice)',
      complete: (prefix) =>
          (reasoningChoices?.call() ?? reasoningEffortWords)
              .where((m) => m.startsWith(prefix))
              .toList(),
      handler: (argument) async {
        if (_closed) return;
        final word = argument.trim().toLowerCase();
        if (word.isEmpty) {
          final current = currentReasoning?.call();
          terminal.writeln(
            current == null || current.isEmpty || current == 'auto'
                ? 'Reasoning: automatic (provider default)'
                : 'Reasoning: $current',
          );
          return;
        }
        if (currentReasoning == null || setReasoning == null) {
          terminal.writeln('Reasoning control is unavailable in this session.');
          return;
        }
        final allowed = reasoningChoices?.call() ?? reasoningEffortWords;
        if (!allowed.contains(word)) {
          terminal.writeln(
            'no reasoning level named $word — choices: ${allowed.join(', ')}',
          );
          return;
        }
        try {
          setReasoning!(word);
          terminal.writeln(
            word == 'auto'
                ? 'Reasoning: automatic (applies to the next request)'
                : 'Reasoning: $word (applies to the next request)',
          );
        } catch (error) {
          terminal.writeln('Could not set reasoning: $error');
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

  /// Commands may use aliases resolved by the provider owner. Picker operations
  /// additionally validate the captured model and the current public catalog.
  void selectModel(String model, {String? expectedModel}) {
    if (_closed) throw StateError('Model controls are closed');
    if (expectedModel != null) {
      if (currentModel() != expectedModel) throw StateError('Model changed');
      if (!modelCatalog().models.contains(model)) {
        throw ArgumentError('Model is no longer available');
      }
    }
    switchModel(model);
    _recentModels.remove(currentModel());
    _recentModels.insert(0, currentModel());
    if (_recentModels.length > 10) _recentModels.removeLast();
  }

  @override
  void closeSession() {
    _closed = true;
    _loop = null;
  }
}

/// Read-only data for owner-side snapshot publication.
final class _SessionControlsObservation implements SessionControlsObservation {
  _SessionControlsObservation(this._plugin);
  final SessionControlsPlugin _plugin;
  @override
  String get currentModel => _plugin.currentModel();
  @override
  ModelCatalog get catalog {
    final value = _plugin.modelCatalog();
    return ModelCatalog(
      models: List.unmodifiable(value.models),
      providerNames: Map.unmodifiable(value.providerNames),
      modelNames: Map.unmodifiable(value.modelNames),
    );
  }

  @override
  List<String> get recentModels => List.unmodifiable(_plugin._recentModels);
}
