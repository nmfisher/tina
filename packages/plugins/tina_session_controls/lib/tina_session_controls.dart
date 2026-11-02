export 'settings.dart';
export 'observation.dart';
export 'operations.dart';
export 'rewind.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'observation.dart';
import 'rewind.dart';
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
    Command(
      name: 'rewind',
      description:
          'rewind the conversation to an earlier point '
          '(/rewind n = back n of your messages)',
      handler: (argument) {
        if (_closed) return;
        final loop = _loop;
        if (loop == null) return;
        final arg = argument.trim();
        if (arg.isEmpty) {
          _printRewindPoints(loop);
          return;
        }
        final back = int.tryParse(arg);
        if (back == null || back < 1) {
          terminal.writeln(
            'usage: /rewind [n] — n is how many of your messages to take back',
          );
          return;
        }
        final points = enumerateRewindPoints(
          loop.log,
        ).where((point) => point.kind == 'user').toList();
        if (points.isEmpty) {
          terminal.writeln('Nothing to rewind to yet.');
          return;
        }
        if (back > points.length) {
          terminal.writeln(
            'Only ${points.length} of your messages exist to rewind past.',
          );
          return;
        }
        rewindTo(
          toSeq: points[points.length - back].toSeq,
          expectedHead: rewindHeadOf(loop.log),
        );
      },
    ),
  ];
  final _recentModels = <String>[];

  /// Rewind the conversation to [toSeq] (exclusive bound), refusing when
  /// the conversation moved since the picker read [expectedHead] — the
  /// same staleness contract the model picker applies. Throws on a busy
  /// loop, an out-of-range bound or a closed session; callers report.
  void rewindTo({required int toSeq, required int expectedHead}) {
    if (_closed) throw StateError('Session controls are closed');
    final loop = _loop;
    if (loop == null) throw StateError('Session controls are closed');
    final head = rewindHeadOf(loop.log);
    if (head != expectedHead) {
      throw StateError('Conversation moved; open the picker again.');
    }
    try {
      loop.rewind(toSeq);
    } on RangeError catch (e) {
      throw StateError('Rewind point is no longer valid: ${e.message}');
    }
    terminal.writeln(_rewindNotice(toSeq));
  }

  /// The one-line scope notice every rewind prints: the conversation
  /// rewinds, the filesystem does not.
  static String _rewindNotice(int toSeq) =>
      'Rewound to entry $toSeq. Filesystem effects of earlier tool calls '
      'are not undone.';

  void _printRewindPoints(AgentLoop loop) {
    final points = enumerateRewindPoints(loop.log);
    if (points.isEmpty) {
      terminal.writeln('Nothing to rewind to yet.');
      return;
    }
    terminal.writeln(
      'Rewind points (current position: after entry ${rewindHeadOf(loop.log)}):',
    );
    for (var i = 0; i < points.length; i++) {
      final stamp = _clock(points[i].at);
      terminal.writeln(
        '  ${i + 1}  $stamp  ${points[i].label}'
        '${points[i].kind == 'compaction' ? '  [compaction]' : ''}',
      );
    }
    terminal.writeln(
      '/rewind <n> takes back your last <n> messages; a console front end '
      'opens a picker for /rewind alone.',
    );
  }

  /// Local HH:mm of a log timestamp, blank when unreadable.
  static String _clock(String at) {
    final time = DateTime.tryParse(at)?.toLocal();
    if (time == null) return '';
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}';
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
  List<String> get recentModels => List.unmodifiable(_plugin._recentModels);
  @override
  List<RewindPoint> get rewindPoints =>
      enumerateRewindPoints(_plugin._loop?.log ?? const []);
  @override
  int get rewindHead => rewindHeadOf(_plugin._loop?.log ?? const []);
}
