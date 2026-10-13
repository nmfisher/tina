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
}
