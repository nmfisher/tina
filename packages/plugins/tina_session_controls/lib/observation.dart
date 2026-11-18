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

/// The profile presets the config defines, as the connection sees them:
/// the names, the resolved `provider/model` reference for each leg (a
/// missing leg key means the leg follows its own fallback), and the
/// profile this conversation runs under. Legs here are the PRESETS —
/// switching copies them into the current values; the current values are
/// the truth.
final class ProfileList {
  const ProfileList({
    required this.active,
    this.names = const [],
    this.legs = const {},
  });
  final String active;
  final List<String> names;

  /// Profile name → leg refs by leg name ('main', 'subagent', 'approver').
  final Map<String, Map<String, String>> legs;
}

/// Model-picker data without a provider, loop or mutation callback.
abstract interface class SessionControlsObservation {
  String get currentModel;
  ModelCatalog get catalog;
  List<String> get recentModels;

  /// The config's profile presets and the active name. Null when this
  /// session has no profile surface (a composition root without the
  /// providers module).
  ProfileList? get profiles;
}
