/// Whether a piece of user input is a project question or an agent
/// instruction. The model scores both categories independently; the decoder
/// picks the higher-scoring one only when it clears the confidence threshold.
///
/// Three decoded states, mirroring the git classifier:
/// - [IntentType.unclear] — unsure, needs more context (also every
///   orchestrator sentinel: oversized input, over-budget, missing service).
/// - `type: null` — clearly neither (chatter, greetings, quotes): the `neither`
///   question cleared 0.9 while both categories scored ≤ 0.1.
/// - otherwise — the detected intent.
enum IntentType { projectQuestion, agentInstruction, unclear }

class IntentResult {
  /// [IntentType.unclear] when nothing cleared its threshold; null when the
  /// input is clearly neither category (see the enum's doc comment).
  final IntentType? type;
  final double confidence;

  /// The dynamic vocabulary's stable ID and presentation label. [type] is a
  /// compatibility projection for the two original built-in categories.
  final String? categoryId, categoryLabel;
  const IntentResult({
    required this.type,
    required this.confidence,
    this.categoryId,
    this.categoryLabel,
  });
  Map<String, Object?> toJson() => {
    'type': type?.name,
    'confidence': confidence,
    if (categoryId != null) 'categoryId': categoryId,
    if (categoryLabel != null) 'categoryLabel': categoryLabel,
  };
}

const gitCommands = [
  'status',
  'diff',
  'log',
  'show',
  'add',
  'commit',
  'push',
  'pull',
  'fetch',
  'branch',
  'switch',
  'checkout',
  'merge',
  'rebase',
  'stash',
  'reset',
  'restore',
  'clone',
  'init',
  'tag',
  'other',
];

class GitIntent {
  final List<String> commands;
  final bool unknown;
  GitIntent({
    Iterable<String> commands = const [],
    this.unknown = false,
    Iterable<String> allowedCommands = gitCommands,
  }) : commands = List.unmodifiable(commands) {
    if (this.commands.any((c) => !allowedCommands.contains(c)) ||
        (unknown && this.commands.isNotEmpty))
      throw FormatException('Invalid Git intent');
  }
  Map<String, Object?> toJson() => {'commands': commands, 'unknown': unknown};
}

final class UtteranceClassification {
  const UtteranceClassification({
    required this.intent,
    this.git,
    this.learningFailed = false,
  });
  factory UtteranceClassification.fromJson(Map data) {
    final intent = data['intent'] as Map;
    final git = data['git'] as Map?;
    final commands =
        (git?['commands'] as List?)?.cast<String>() ?? const <String>[];
    return UtteranceClassification(
      intent: IntentResult(
        type: intent['type'] == null
            ? null
            : IntentType.values.byName(intent['type'] as String),
        confidence: (intent['confidence'] as num).toDouble(),
        categoryId: intent['categoryId'] as String?,
        categoryLabel: intent['categoryLabel'] as String?,
      ),
      git: git == null
          ? null
          : GitIntent(
              commands: commands,
              // The runtime validates against its learned category catalog.
              // A display decoder must also preserve categories added there.
              allowedCommands: commands,
              unknown: git['unknown'] as bool,
            ),
      learningFailed: data['learningFailed'] == true,
    );
  }
  final IntentResult intent;

  /// Absent when the utterance was not classified as an instruction.
  final GitIntent? git;
  final bool learningFailed;
  Map<String, Object?> toJson() => {
    'intent': intent.toJson(),
    if (git != null) 'git': git!.toJson(),
    if (learningFailed) 'learningFailed': true,
  };
  String get label {
    final intentLabel =
        intent.categoryLabel ??
        switch (intent.type) {
          IntentType.projectQuestion => 'project question',
          IntentType.agentInstruction => 'instruction',
          IntentType.unclear => 'unclear',
          null => 'neither question nor instruction',
        };
    final git = this.git;
    final suffix = learningFailed ? ' · learning unavailable' : '';
    if (git == null) return '$intentLabel$suffix';
    return '$intentLabel · git: ${git.unknown
        ? 'unclear'
        : git.commands.isEmpty
        ? 'no'
        : git.commands.join(', ')}$suffix';
  }
}
