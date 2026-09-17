/// Persisted settings for structured judgments, separate from chat providers.
class TypeSafeSettings {
  final String? apiKey;
  final String? model;
  final int? explorationTokenBudget;
  final int? explorationTimeoutSeconds;
  final int? explorationMetadataTokenBudget;
  final double? explorationSelectionThreshold;
  const TypeSafeSettings({
    this.apiKey,
    this.model,
    this.explorationTokenBudget,
    this.explorationTimeoutSeconds,
    this.explorationMetadataTokenBudget,
    this.explorationSelectionThreshold,
  });

  TypeSafeSettings withApiKey(String? value) => TypeSafeSettings(
    apiKey: value,
    model: model,
    explorationTokenBudget: explorationTokenBudget,
    explorationTimeoutSeconds: explorationTimeoutSeconds,
    explorationMetadataTokenBudget: explorationMetadataTokenBudget,
    explorationSelectionThreshold: explorationSelectionThreshold,
  );

  factory TypeSafeSettings.fromMap(Map<String, dynamic> map) =>
      TypeSafeSettings(
        apiKey: map['api_key'] as String?,
        model: map['model'] as String?,
        explorationTokenBudget: map['exploration_token_budget'] as int?,
        explorationTimeoutSeconds: map['exploration_timeout_seconds'] as int?,
        explorationMetadataTokenBudget:
            map['exploration_metadata_token_budget'] as int?,
        explorationSelectionThreshold:
            (map['exploration_selection_threshold'] as num?)?.toDouble(),
      );

  bool get isEmpty =>
      apiKey == null &&
      model == null &&
      explorationTokenBudget == null &&
      explorationTimeoutSeconds == null &&
      explorationMetadataTokenBudget == null &&
      explorationSelectionThreshold == null;
  Map<String, Object?> toMap() => {
    if (apiKey != null) 'api_key': apiKey,
    if (model != null) 'model': model,
    if (explorationTokenBudget != null)
      'exploration_token_budget': explorationTokenBudget,
    if (explorationMetadataTokenBudget != null)
      'exploration_metadata_token_budget': explorationMetadataTokenBudget,
    if (explorationSelectionThreshold != null)
      'exploration_selection_threshold': explorationSelectionThreshold,
    if (explorationTimeoutSeconds != null)
      'exploration_timeout_seconds': explorationTimeoutSeconds,
  };

  @override
  bool operator ==(Object other) =>
      other is TypeSafeSettings &&
      apiKey == other.apiKey &&
      model == other.model &&
      explorationTokenBudget == other.explorationTokenBudget &&
      explorationTimeoutSeconds == other.explorationTimeoutSeconds &&
      explorationMetadataTokenBudget == other.explorationMetadataTokenBudget &&
      explorationSelectionThreshold == other.explorationSelectionThreshold;
  @override
  int get hashCode => Object.hash(
    apiKey,
    model,
    explorationTokenBudget,
    explorationTimeoutSeconds,
    explorationMetadataTokenBudget,
    explorationSelectionThreshold,
  );
}
