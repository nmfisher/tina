import 'rewind.dart';

export 'rewind.dart' show RewindPoint;

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

/// Model-picker data without a provider, loop or mutation callback.
abstract interface class SessionControlsObservation {
  String get currentModel;
  ModelCatalog get catalog;
  List<String> get recentModels;

  /// Rewind points of the live log, oldest first, plus the current
  /// position — the picker's data. Empty when the conversation has no
  /// rewindable history yet.
  List<RewindPoint> get rewindPoints;

  /// The seq of the last live entry, or -1 — the conversation's current
  /// position. A rewind request carries the head it was planned against.
  int get rewindHead;
}
