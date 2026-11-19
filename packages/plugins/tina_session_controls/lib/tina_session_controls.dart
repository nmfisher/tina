export 'settings.dart';
export 'observation.dart';
export 'operations.dart';
export 'memory_command.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_memory/tina_memory.dart'
    show AnswerCacheStats, MemoryStorePair;
import 'memory_command.dart';
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
    this.readProfiles,
    this.switchProfile,
    this.openMemoryStores,
    this.readCacheStats,
  });
  final Terminal terminal;
  final String Function() currentModel;
  final void Function(String) switchModel;
  // Read at use, including when this plugin is enabled after a settings save.
  final ModelCatalog Function() modelCatalog;

  /// The config's profile presets and the active name. Null disables
  /// /profile (compositions without the providers module).
  final ProfileList Function()? readProfiles;

  /// Copy a named profile's legs into this conversation's current values.
  /// Throws on an unknown name; the command layer reports it.
  final void Function(String profile)? switchProfile;

  /// The conversation's effective reasoning effort, or null when the host
  /// has no settings stack (headless with no config). Null disables /reasoning.
  final String? Function()? currentReasoning;

  /// Persist a reasoning choice for this conversation. Throws on rejection;
  /// 'auto' removes the override. Null disables /reasoning.
  final void Function(String)? setReasoning;

  /// Effort words the current model accepts, for completion and validation.
  /// Null means every canonical word is offered.
  final List<String> Function()? reasoningChoices;

  /// Rolling-memory access for /memory: opens the store pair the way
  /// the CLI does (`openDefaultMemoryStores`), called once per command
  /// with the pair closed after. Null disables /memory — the wasm
  /// engine path and compositions without memory.
  final MemoryStorePair Function()? openMemoryStores;

  /// The session's live answer-cache scoreboard for /memory stats; null
  /// when no memory plugin is attached (stats then says so).
  final AnswerCacheStats? Function()? readCacheStats;
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
    // /memory exists only where the composition supplied the CLI's
    // store-opening path — by construction it stays off the wasm
    // engine, whose registry wires this plugin without the seam.
    if (openMemoryStores case final openMemory?)
      memoryCommand(
        terminal: terminal,
        openStores: openMemory,
        readCacheStats: readCacheStats,
      ),
    Command(
      name: 'model',
      description: 'pick or change this conversation model',
      // Switching re-points future requests only: between-turns work such
      // as a running /compact keeps its provider, and the loop installs
      // the replacement when that work ends.
      allowWhileRunning: true,
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
      name: 'profile',
      description: 'switch model profiles (empty lists them)',
      // Switching copies the profile's legs into the current values; the
      // main leg re-points future requests exactly like /model.
      allowWhileRunning: true,
      complete: (prefix) => (readProfiles?.call().names ?? const [])
          .where((name) => name.startsWith(prefix))
          .toList(),
      handler: (argument) async {
        if (_closed) return;
        final profiles = readProfiles?.call();
        if (profiles == null) {
          terminal.writeln('Profiles are unavailable in this session.');
          return;
        }
        final name = argument.trim();
        if (name.isEmpty) {
          terminal.writeln('Profile: ${profiles.active}');
          for (final candidate in profiles.names) {
            terminal.writeln(
                '${candidate == profiles.active ? '*' : ' '} $candidate'
                '${_describeLegs(profiles, candidate)}');
          }
          return;
        }
        if (!profiles.names.contains(name)) {
          terminal.writeln('no profile named $name — choices: '
              '${profiles.names.join(', ')}');
          return;
        }
        try {
          switchProfile!(name);
          terminal.writeln('Profile: ${readProfiles!().active}');
        } catch (error) {
          terminal.writeln('Could not switch profile: $error');
        }
      },
    ),
    Command(
      name: 'reasoning',
      description:
          'reasoning effort: ${reasoningEffortWords.join(', ')} (empty shows the current choice)',
      complete: (prefix) => (reasoningChoices?.call() ?? reasoningEffortWords)
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

  /// One profile's legs for the listing: `main · subagent · approver`
  /// refs, omitting legs the profile leaves to their own fallbacks.
  static String _describeLegs(ProfileList profiles, String name) {
    final legs = profiles.legs[name] ?? const {};
    final parts = [
      for (final leg in const ['main', 'subagent', 'approver'])
        if (legs[leg] case final ref?) '$leg $ref',
    ];
    return parts.isEmpty ? '' : ' — ${parts.join(' · ')}';
  }

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
  ProfileList? get profiles => _plugin.readProfiles?.call();

  @override
  List<String> get recentModels => List.unmodifiable(_plugin._recentModels);
}
